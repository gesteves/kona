require "digest"

# Publishes the blog to the AT Protocol as standard.site records, driven by Contentful
# webhooks plus the `standard_site:backfill` rake task:
#   - one site.standard.publication record tracks the site,
#   - one site.standard.document record per published Article/Short tracks each post,
#   - records are pruned when a post is unpublished or deleted.
#
# A SHA-256 fingerprint of each record's content is cached in Redis, so the expensive part
# (a cover-image blob upload plus a putRecord) only runs when the content actually changed.
# Everything no-ops without Bluesky credentials.
# @see https://standard.site
class StandardSite < ApplicationService
  include ContentfulConsumer

  # AT Protocol "sortable base32" alphabet. Both standard.site lexicons require every record
  # key to be a TID, so no natural id can be used as an rkey directly.
  # @see https://atproto.com/specs/tid
  TID_ALPHABET = "234567abcdefghijklmnopqrstuvwxyz"

  # Derives a stable TID from a seed: the low 63 bits of its SHA-256 digest, base32-encoded.
  # web's StandardSiteHelpers#document_rkey must use the identical algorithm, or the AT URI it
  # emits won't match the record published here.
  # @param seed [String]
  # @return [String] A 13-character TID.
  def self.tid(seed)
    value = Digest::SHA256.hexdigest(seed.to_s).to_i(16) & ((1 << 63) - 1)
    encoded = +""
    while value.positive?
      encoded = TID_ALPHABET[value % 32] + encoded
      value /= 32
    end
    encoded.rjust(13, TID_ALPHABET[0])
  end

  # Builds a site.standard.theme.color#rgb value.
  # @param r [Integer] Red channel, 0-255.
  # @param g [Integer] Green channel, 0-255.
  # @param b [Integer] Blue channel, 0-255.
  # @return [Hash]
  def self.rgb(r, g, b)
    { "$type" => "site.standard.theme.color#rgb", "r" => r, "g" => g, "b" => b }
  end

  # The publication's theme, for readers that render the site's content in their own chrome.
  # ⚠️ Mirrors web's LIGHT-mode tokens in web/source/stylesheets/base/_props.scss; the lexicon
  # has no dark-mode counterpart. Nothing checks the two stay in step.
  BASIC_THEME = {
    "$type" => "site.standard.theme.basic",
    "background" => rgb(255, 255, 255),       # white
    "foreground" => rgb(41, 41, 41),          # --color-text / --color-jet #292929
    "accent" => rgb(191, 2, 34),              # --color-firebrick #BF0222 (brand)
    "accentForeground" => rgb(250, 250, 250)  # --color-button-text / --color-cultured #FAFAFA
  }.freeze

  PUBLICATION_COLLECTION = "site.standard.publication"
  DOCUMENT_COLLECTION = "site.standard.document"
  # The publication is the repo's singleton, at a stable TID derived from the "self" seed.
  PUBLICATION_RKEY = tid("self")
  # Where the publication used to live, before the lexicon required a TID. Backfill prunes it.
  LEGACY_PUBLICATION_RKEY = "self"
  DEFAULT_PDS_URL = "https://bsky.social"
  # A DID is stable for an account, so it's cached without a TTL.
  DID_CACHE_KEY = "standard_site:did"

  # Sanity guard for a Contentful sys.id before it's turned into a record key.
  ENTRY_ID_PATTERN = /\A[a-zA-Z0-9._~:-]{1,512}\z/

  # Builds the publication's at:// URI. The single source of truth for the format, shared by
  # the sync paths and the /api/standard-site endpoint.
  # @param did [String]
  # @return [String]
  def self.publication_uri(did)
    "at://#{did}/#{PUBLICATION_COLLECTION}/#{PUBLICATION_RKEY}"
  end

  # The article fields the document builders need, shared by the by-id and list queries.
  ARTICLE_ITEM_FIELDS = <<~GRAPHQL.freeze
    title
    slug
    intro
    body
    summary
    published
    coverImage { url contentType }
    contentfulMetadata { concepts { id } }
    sys { id firstPublishedAt publishedAt publishedVersion }
  GRAPHQL

  ARTICLE_QUERY = <<~GRAPHQL.freeze
    query($id: String!) {
      articles: articleCollection(where: { sys: { id: $id } }, limit: 1) {
        items { #{ARTICLE_ITEM_FIELDS} }
      }
    }
  GRAPHQL

  ARTICLES_LIST_QUERY = <<~GRAPHQL.freeze
    query($skip: Int, $limit: Int) {
      articles: articleCollection(skip: $skip, limit: $limit) {
        items { #{ARTICLE_ITEM_FIELDS} }
      }
    }
  GRAPHQL

  SITE_QUERY = <<~GRAPHQL.freeze
    query {
      sites: siteCollection(limit: 1, order: [sys_publishedAt_DESC]) {
        items {
          title
          metaDescription
          logo { url contentType }
        }
      }
    }
  GRAPHQL

  # @param credentials [BlueskyCredentials::Credentials] The pair to authenticate with. Injected
  #   so the admin can validate a pair the owner just typed, before it's stored.
  def initialize(credentials: BlueskyCredentials.fetch)
    @handle = credentials.handle
    @app_password = credentials.app_password
    @pds_url = (ENV["BLUESKY_PDS_URL"].presence || DEFAULT_PDS_URL).chomp("/")
  end

  # Syncs an entry's document record. The entry is re-fetched from the delivery API rather
  # than read from the webhook body, whose cover image is an unresolved link and whose tags
  # lack names; the retries absorb Contentful's brief post-publish propagation lag. A draft,
  # non-publishable, or vanished entry is treated as a delete.
  # @param entry_id [String] The Contentful sys.id.
  # @return [Symbol] :synced, :unchanged, :deleted, or :skipped.
  def sync_document(entry_id)
    return log_skip("document #{entry_id}", "no Bluesky credentials") unless valid_credentials?
    return log_skip("document #{entry_id}", "invalid entry id") unless eligible?(entry_id)
    return log_skip("document #{entry_id}", "could not authenticate with the PDS") unless create_session

    item = with_retries(max: 3) do
      found = fetch_article(entry_id)
      raise "not yet available" if found.blank?
      found
    end
    post = item && decorate_post(item)
    if post.blank? || publishable_posts([ post ]).empty?
      log("entry #{entry_id} is not a publishable post; removing any document record")
      return remove_document!(document_rkey(entry_id))
    end

    publication_uri = self.class.publication_uri(@did)
    do_sync_document(post, document_rkey(entry_id), publication_uri)
  end

  # Removes an unpublished or deleted entry's document record. Idempotent.
  # @param entry_id [String] The Contentful sys.id.
  # @return [Symbol] :deleted or :skipped.
  def delete_document(entry_id)
    return log_skip("document #{entry_id}", "no Bluesky credentials") unless valid_credentials?
    return log_skip("document #{entry_id}", "invalid entry id") unless eligible?(entry_id)
    return log_skip("document #{entry_id}", "could not authenticate with the PDS") unless create_session

    remove_document!(document_rkey(entry_id))
  end

  # Re-syncs the publication record from the current site entry.
  # @return [Symbol] :synced, :unchanged, or :skipped.
  def sync_publication
    return log_skip("publication", "no Bluesky credentials") unless valid_credentials?
    return log_skip("publication", "could not authenticate with the PDS") unless create_session

    site = fetch_site
    return log_skip("publication", "no site data") if site.blank?
    do_sync_publication(site)
  end

  # Reconciles the whole PDS repo with the published Contentful corpus: syncs the publication,
  # enqueues a sync job per publishable post, then prunes orphaned document records. The safety
  # net for webhook deliveries that failed, since Contentful doesn't retry them.
  # Needs a running Sidekiq worker to drain the enqueued jobs. Pruning is inline and safe to
  # run immediately, since it only touches records outside the published set.
  def backfill
    return log_skip("backfill", "no Bluesky credentials") unless valid_credentials?
    return log_skip("backfill", "could not authenticate with the PDS") unless create_session

    log("backfill starting")
    site = fetch_site
    return log_skip("backfill", "no site data") if site.blank?
    do_sync_publication(site)
    prune_legacy_publication

    items = fetch_all_articles
    # Bail before pruning, so a transient fetch error can't prune live records to nothing.
    return log_skip("backfill", "article fetch failed; not pruning") if items.nil?

    current = []
    publishable_posts(items.map { |item| decorate_post(item) }).each do |post|
      sys_id = post.dig("sys", "id")
      next if sys_id.blank? || !ENTRY_ID_PATTERN.match?(sys_id)
      current << document_rkey(sys_id)
      StandardSiteSyncJob.perform_async("sync_document", sys_id)
    end

    pruned = prune_documents(current)
    log("backfill complete: #{current.size} document sync job(s) enqueued, #{pruned} record(s) pruned")
  end

  # The account's DID, from the Redis cache, resolving a session on demand when absent.
  # @return [String, nil] The DID, or nil without credentials or when resolution fails.
  def did
    rescue_with(context: "standard.site DID") do
      cached = $redis.get(DID_CACHE_KEY)
      next cached if cached.present?
      next nil unless valid_credentials?
      create_session ? @did : nil
    end
  end

  # @return [Boolean] true if both Bluesky credentials are present.
  def valid_credentials?
    @handle.present? && @app_password.present?
  end

  # Whether an account is attached, for the Connected apps page. Deliberately not a live
  # createSession: the page renders this on every load, and a PDS round trip there would put an
  # upstream outage in the path of the admin's own navigation.
  # @return [Boolean]
  def connected? = valid_credentials?

  # Validates a credential pair by opening a session with it, and stores it on success. The DID
  # the session resolves is cached in the same step.
  #
  # ⚠️ On a DID change the publication record's fingerprint has to go. Document fingerprints
  # cover the publication's at:// URI, which carries the DID, so they invalidate themselves when
  # the account changes; the publication record's doesn't, and a stale one would report
  # :unchanged forever and never sync to the new repo.
  # @return [Boolean] Whether the credentials opened a session and were stored.
  def connect!
    return false unless valid_credentials?

    previous_did = $redis.get(DID_CACHE_KEY)
    return false unless create_session

    $redis.del(fingerprint_key(PUBLICATION_COLLECTION, PUBLICATION_RKEY)) if previous_did.present? && previous_did != @did
    BlueskyCredentials.store(handle: @handle, app_password: @app_password)
    true
  end

  # Forgets the stored credentials.
  #
  # ⚠️ Leaves DID_CACHE_KEY alone. The DID is public data, not a credential, and the records it
  # addresses still exist — GET /api/standard-site feeds the verification <link> tags on every
  # page of the static site, so clearing it here would silently strip them site-wide at the next
  # build.
  # @return [void]
  def disconnect!
    BlueskyCredentials.clear
  end

  # Selects the posts that should have a document record: published Articles and Shorts.
  # Pages are deliberately excluded.
  # @param posts [Array<Hash>] Decorated posts, string-keyed.
  # @return [Array<Hash>]
  def publishable_posts(posts)
    Array(posts).select { |a| !a["draft"] && %w[Article Short].include?(a["entry_type"]) }
  end

  # Builds a site.standard.publication record. The icon is passed in rather than uploaded
  # here, so the record can be built network-free for fingerprinting.
  # @param site [Hash] Decorated site, string-keyed.
  # @param icon [Hash, String, nil] The uploaded blob, or a source descriptor when
  #   fingerprinting.
  # @return [Hash]
  def build_publication_record(site, icon: nil)
    record = {
      "$type" => PUBLICATION_COLLECTION,
      "url" => publication_url,
      "name" => truncate_graphemes(site["title"].to_s, 500),
      "basicTheme" => BASIC_THEME,
      "preferences" => { "showInDiscover" => true }
    }
    description = plain_text(site["meta_description"])
    record["description"] = truncate_graphemes(description, 3000) if description.present?
    record["icon"] = icon if icon.present?
    record
  end

  # Builds a site.standard.document record. The cover image is passed in rather than uploaded
  # here, so the record can be built network-free for fingerprinting.
  # @param post [Hash] A decorated post, string-keyed.
  # @param publication_uri [String] The publication's at:// URI.
  # @param cover_image [Hash, String, nil] The uploaded blob, or a source descriptor when
  #   fingerprinting.
  # @return [Hash]
  def build_document_record(post, publication_uri, cover_image: nil)
    record = {
      "$type" => DOCUMENT_COLLECTION,
      "site" => publication_uri,
      "title" => truncate_graphemes(post["title"].to_s, 500),
      "publishedAt" => iso8601(post["published_at"])
    }
    path = document_path(post["path"])
    record["path"] = path if path.present?
    updated = iso8601(post["updated_at"])
    record["updatedAt"] = updated if updated.present?

    description = plain_text(post["summary"].presence || post["intro"])
    record["description"] = truncate_graphemes(description, 3000) if description.present?

    text = plain_text([ post["intro"], post["body"] ].reject(&:blank?).join("\n\n"))
    record["textContent"] = text if text.present?

    tags = Array(post.dig("contentful_metadata", "tags")).map { |t| t["name"] }.compact_blank
    record["tags"] = tags if tags.present?

    record["coverImage"] = cover_image if cover_image.present?
    record
  end

  # An entry's document record key, derived from the sys.id alone so sync, delete, and prune
  # all compute the same key — a delete has no post data to work from.
  # @param entry_id [String] The Contentful sys.id.
  # @return [String] A 13-character TID.
  def document_rkey(entry_id)
    self.class.tid(entry_id)
  end

  # @param existing [Array<String>] rkeys currently in the document collection.
  # @param current [Array<String>] rkeys that should remain.
  # @return [Array<String>] The rkeys on the PDS that are no longer current.
  def rkeys_to_prune(existing, current)
    Array(existing) - Array(current)
  end

  # A content fingerprint for a post's document record, built from the same builder as the
  # synced record with the cover image standing in as its source URL — so a swapped image
  # still changes the fingerprint, without a network round trip.
  # @param post [Hash] A decorated post, string-keyed.
  # @param publication_uri [String] The publication's at:// URI.
  # @return [String]
  def document_fingerprint(post, publication_uri)
    record = build_document_record(post, publication_uri, cover_image: cover_source(post["cover_image"]))
    Digest::SHA256.hexdigest(record.to_json)
  end

  # A content fingerprint for the publication record.
  # @param site [Hash] Decorated site, string-keyed.
  # @return [String]
  def publication_fingerprint(site)
    record = build_publication_record(site, icon: cover_source(site["logo"]))
    Digest::SHA256.hexdigest(record.to_json)
  end

  private

  # Logs a one-line operation message at info level and returns `result`, so callers can
  # `return log(msg, :result)`.
  # @return The passed-through result.
  def log(message, result = nil)
    Rails.logger.info("standard.site: #{message}")
    result
  end

  # Logs why an operation was skipped and returns :skipped.
  def log_skip(subject, reason)
    log("#{subject} skipped (#{reason})", :skipped)
  end

  # @param entry_id [String, nil]
  # @return [Boolean] true if the id is a usable AT Protocol record key.
  def eligible?(entry_id)
    entry_id.present? && ENTRY_ID_PATTERN.match?(entry_id.to_s)
  end

  # A stable descriptor of an image's source, standing in for an uploaded blob when
  # fingerprinting. Contentful URLs are version-addressed, so a replaced asset changes it.
  # @param image [Hash, nil] An object with 'url' and 'content_type' keys.
  # @return [String, nil]
  def cover_source(image)
    url = image&.dig("url")
    return if url.blank?
    "#{url}|#{image['content_type']}"
  end

  # Syncs the publication record, skipping the upload and putRecord when its fingerprint is
  # unchanged.
  # @param site [Hash] Decorated site, string-keyed.
  # @return [Symbol] :unchanged, :synced, or :error.
  def do_sync_publication(site)
    fingerprint = publication_fingerprint(site)
    if fingerprint == stored_fingerprint(PUBLICATION_COLLECTION, PUBLICATION_RKEY)
      return log("publication unchanged; skipping", :unchanged)
    end
    icon = upload_image_blob(site.dig("logo", "url"), site.dig("logo", "content_type"), w: 512, h: 512)
    record = build_publication_record(site, icon: icon)
    unless put_record(PUBLICATION_COLLECTION, PUBLICATION_RKEY, record)
      return log("publication putRecord failed", :error)
    end
    store_fingerprint(PUBLICATION_COLLECTION, PUBLICATION_RKEY, fingerprint)
    log("publication synced", :synced)
  end

  # Deletes the publication record at the legacy "self" rkey, which the lexicon no longer
  # accepts. Idempotent, so it can run on every backfill.
  def prune_legacy_publication
    return if PUBLICATION_RKEY == LEGACY_PUBLICATION_RKEY
    delete_record(PUBLICATION_COLLECTION, LEGACY_PUBLICATION_RKEY)
  end

  # Syncs one document record, skipping the cover-image upload and putRecord when its
  # fingerprint is unchanged.
  # @param post [Hash] A decorated post, string-keyed.
  # @param rkey [String] The record key.
  # @param publication_uri [String] The publication's at:// URI.
  # @return [Symbol] :unchanged, :synced, or :error.
  def do_sync_document(post, rkey, publication_uri)
    fingerprint = document_fingerprint(post, publication_uri)
    if fingerprint == stored_fingerprint(DOCUMENT_COLLECTION, rkey)
      return log("document #{rkey} unchanged; skipping", :unchanged)
    end
    cover = upload_image_blob(post.dig("cover_image", "url"), post.dig("cover_image", "content_type"), w: 1200, h: 630)
    record = build_document_record(post, publication_uri, cover_image: cover)
    unless put_record(DOCUMENT_COLLECTION, rkey, record)
      return log("document #{rkey} putRecord failed", :error)
    end
    store_fingerprint(DOCUMENT_COLLECTION, rkey, fingerprint)
    log("document #{rkey} synced", :synced)
  end

  # Deletes a document record by rkey and forgets its fingerprint.
  #
  # ⚠️ The fingerprint is only forgotten once the delete actually succeeded. Dropping it after a
  # failed delete leaves the record live on the PDS with nothing left to notice the drift, and the
  # job returns as if it had worked.
  # @return [Symbol] :deleted, or :error when the PDS rejected the delete.
  def remove_document(rkey)
    return log("document #{rkey} deleteRecord failed", :error) unless delete_record(DOCUMENT_COLLECTION, rkey)

    forget_fingerprint(rkey)
    log("document #{rkey} deleted", :deleted)
  end

  # remove_document, but raising on failure so Sidekiq retries the job.
  #
  # ⚠️ The backfill's prune path deliberately calls remove_document instead — one unreachable
  # record must not abort a whole reconciliation run.
  # @return [Symbol] :deleted.
  def remove_document!(rkey)
    result = remove_document(rkey)
    raise "could not delete document #{rkey} from the PDS" if result == :error

    result
  end

  # --- Contentful (delivery API) ------------------------------------------------------

  # @param entry_id [String] The Contentful sys.id.
  # @return [Hash, nil] The raw symbolized article item, or nil when missing or failed.
  def fetch_article(entry_id)
    query_contentful(ARTICLE_QUERY, { id: entry_id })&.dig(:articles, :items)&.first
  end

  # @return [Hash, nil] The decorated site, string-keyed, or nil when missing or failed.
  def fetch_site
    item = query_contentful(SITE_QUERY)&.dig(:sites, :items)&.first
    item && decorate_site(item)
  end

  # Pages through the whole article collection. Strict, because the sync must never act on a
  # partial corpus.
  # @return [Array<Hash>, nil] Every raw article item, or nil if any page failed.
  def fetch_all_articles
    contentful.paginate(ARTICLES_LIST_QUERY, collection: :articles, strict: true)
  end

  # @return [Hash, nil] The query's `data`, or nil when unconfigured or the request failed.
  def query_contentful(query, variables = nil)
    contentful.query(query, variables)
  end

  # Maps a raw GraphQL article item to the string-keyed shape the record builders expect.
  # ArticleAttributes keeps draft, entry_type, and path consistent with the rest of the app.
  # @param item [Hash] A raw symbolized article item.
  # @return [Hash]
  def decorate_post(item)
    sys = item[:sys] || {}
    derived = ArticleAttributes.derive(
      slug: item[:slug],
      published_version: sys[:publishedVersion],
      published: item[:published],
      first_published_at: sys[:firstPublishedAt],
      body: item[:body]
    )
    cover = item[:coverImage]

    {
      "sys" => { "id" => sys[:id] },
      "title" => item[:title],
      "slug" => item[:slug],
      "summary" => item[:summary],
      "intro" => item[:intro],
      "body" => item[:body],
      "entry_type" => derived[:entry_type],
      "draft" => derived[:draft],
      "published_at" => derived[:published_at],
      "updated_at" => sys[:publishedAt],
      "path" => derived[:path],
      "cover_image" => cover && { "url" => cover[:url], "content_type" => cover[:contentType] },
      "contentful_metadata" => {
        "tags" => article_tags(item)
      }
    }
  end

  # The article's tags for the record, joining the concept ids GraphQL returns to their names.
  # Concepts whose name can't be resolved are dropped.
  # @param item [Hash] A raw symbolized article item.
  # @return [Array<Hash>] { "id", "name" } hashes.
  def article_tags(item)
    Array(item.dig(:contentfulMetadata, :concepts)).filter_map do |concept|
      name = taxonomy_names[concept[:id].to_s]
      { "id" => concept[:id], "name" => name } if name.present?
    end
  end

  # Concept id => name for the whole taxonomy, fetched once per sync. Empty when unavailable.
  # @return [Hash{String=>String}]
  def taxonomy_names
    @taxonomy_names ||= TaxonomyConcepts.new.names || {}
  end

  # @param item [Hash] A raw symbolized site item.
  # @return [Hash] The string-keyed site the publication builder expects.
  def decorate_site(item)
    logo = item[:logo]
    {
      "title" => item[:title],
      "meta_description" => item[:metaDescription],
      "logo" => logo && { "url" => logo[:url], "content_type" => logo[:contentType] }
    }
  end

  # --- Fingerprint cache (this app's Redis; not read by the web app) ------------------

  # The Redis key a record's fingerprint is cached under, scoped by collection so a document
  # and the publication can't collide on rkey.
  def fingerprint_key(collection, rkey)
    "standard_site:fingerprint:#{collection}:#{rkey}"
  end

  # @return [String, nil] The last-synced fingerprint, or nil when absent.
  def stored_fingerprint(collection, rkey)
    return unless defined?($redis) && $redis
    $redis.get(fingerprint_key(collection, rkey))
  end

  # Persists a record's fingerprint, with no TTL — it outlives any single sync.
  def store_fingerprint(collection, rkey, value)
    return unless defined?($redis) && $redis
    $redis.set(fingerprint_key(collection, rkey), value)
  end

  # Drops a pruned record's cached fingerprint, so it re-syncs if it ever reappears.
  def forget_fingerprint(rkey)
    return unless defined?($redis) && $redis
    $redis.del(fingerprint_key(DOCUMENT_COLLECTION, rkey))
  end

  # @return [String] The production site root, without a trailing slash.
  def publication_url
    ENV["SITE_URL"].to_s.chomp("/")
  end

  # Normalizes a post path to the canonical page URL, so document verification fetches the
  # page that actually carries the <link> tag.
  # @param path [String] The decorated post path.
  # @return [String, nil]
  def document_path(path)
    return if path.blank?
    cleaned = path.to_s.sub(/index\.html\z/, "")
    cleaned.start_with?("/") ? cleaned : "/#{cleaned}"
  end

  # --- PDS (AT Protocol) --------------------------------------------------------------

  # Authenticates with the PDS, resolving the DID and the repo's service endpoint, and caches
  # the DID.
  # @return [Boolean] Whether a usable session was established.
  def create_session
    return false unless valid_credentials?

    response = HTTParty.post(
      "#{@pds_url}/xrpc/com.atproto.server.createSession",
      body: { identifier: @handle, password: @app_password }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
    unless response.success?
      Rails.logger.warn("standard.site: failed to authenticate with the PDS (HTTP #{response.code})")
      report_upstream_error("HTTP #{response.code}", context: "standard.site PDS session", status: response.code)
      return false
    end
    data = JSON.parse(response.body)
    @access_jwt = data["accessJwt"]
    @did = data["did"]
    @service_url = pds_endpoint_from_did_doc(data["didDoc"]) || @pds_url
    $redis.set(DID_CACHE_KEY, @did) if @did.present? && defined?($redis) && $redis
    @access_jwt.present? && @did.present?
  rescue StandardError => e
    Rails.logger.error("standard.site: error creating PDS session: #{e.message}")
    report_upstream_error(e, context: "standard.site PDS session")
    false
  end

  # @param doc [Hash, nil] A DID document.
  # @return [String, nil] Its #atproto_pds service endpoint.
  def pds_endpoint_from_did_doc(doc)
    return if doc.blank?
    service = Array(doc["service"]).find { |s| s["id"].to_s.end_with?("#atproto_pds") }
    service&.dig("serviceEndpoint")&.chomp("/")
  end

  # Creates or updates a record, idempotent on repo + collection + rkey. Sends validate:false
  # because the PDS doesn't know the site.standard.* lexicons.
  # @return [Boolean] Whether it succeeded.
  def put_record(collection, rkey, record)
    response = HTTParty.post(
      "#{@service_url}/xrpc/com.atproto.repo.putRecord",
      body: { repo: @did, collection: collection, rkey: rkey, validate: false, record: record }.to_json,
      headers: auth_headers
    )
    unless response.success?
      Rails.logger.warn("standard.site: failed to put #{collection}/#{rkey} (HTTP #{response.code}: #{response.body})")
      report_upstream_error("HTTP #{response.code}", context: "standard.site putRecord #{collection}/#{rkey}", status: response.code)
    end
    response.success?
  end

  # Deletes every document record whose rkey isn't in the current set.
  # @param current_rkeys [Array<String>] The rkeys that should remain.
  # @return [Integer] How many records were pruned.
  def prune_documents(current_rkeys)
    stale = rkeys_to_prune(list_record_rkeys(DOCUMENT_COLLECTION), current_rkeys)
    stale.count { |rkey| remove_document(rkey) == :deleted }
  end

  # @param collection [String] The collection to list.
  # @return [Array<String>] Every rkey in it, paged through the cursor.
  def list_record_rkeys(collection)
    rkeys = []
    cursor = nil
    loop do
      query = { repo: @did, collection: collection, limit: 100 }
      query[:cursor] = cursor if cursor.present?
      response = HTTParty.get("#{@service_url}/xrpc/com.atproto.repo.listRecords", query: query, headers: auth_headers)
      unless response.success?
        report_upstream_error("HTTP #{response.code}", context: "standard.site listRecords #{collection}", status: response.code)
        break
      end
      body = JSON.parse(response.body)
      records = Array(body["records"])
      rkeys.concat(records.map { |r| r["uri"].to_s.split("/").last })
      cursor = body["cursor"]
      break if cursor.blank? || records.empty?
    end
    rkeys
  end

  # @param collection [String]
  # @param rkey [String]
  # @return [Boolean] Whether it succeeded.
  def delete_record(collection, rkey)
    response = HTTParty.post(
      "#{@service_url}/xrpc/com.atproto.repo.deleteRecord",
      body: { repo: @did, collection: collection, rkey: rkey }.to_json,
      headers: auth_headers
    )
    unless response.success?
      Rails.logger.warn("standard.site: failed to delete #{collection}/#{rkey} (HTTP #{response.code}: #{response.body})")
      report_upstream_error("HTTP #{response.code}", context: "standard.site deleteRecord #{collection}/#{rkey}", status: response.code)
    end
    response.success?
  end

  # Downloads a resized copy of an image and uploads it to the PDS as a blob.
  # @return [Hash, nil] The blob, or nil on any failure or without a session — in which case
  #   the caller omits the field.
  def upload_image_blob(url, content_type, w:, h:)
    return if @access_jwt.blank? || url.blank?
    bytes, mime = fetch_resized_image(url, content_type, w: w, h: h)
    return if bytes.blank?
    response = HTTParty.post(
      "#{@service_url}/xrpc/com.atproto.repo.uploadBlob",
      body: bytes,
      headers: { "Content-Type" => mime, "Authorization" => "Bearer #{@access_jwt}" }
    )
    unless response.success?
      report_upstream_error("HTTP #{response.code}", context: "standard.site uploadBlob", status: response.code)
      return
    end
    JSON.parse(response.body)["blob"]
  rescue StandardError => e
    report_upstream_error(e, context: "standard.site uploadBlob")
    nil
  end

  # Fetches a resized image as raw bytes via Contentful's Images API, keeping blobs under 1MB.
  # Hitting Contentful directly is fine here, since this only runs on publish.
  # @return [Array(String, String), nil] [bytes, mime_type], or nil on failure.
  def fetch_resized_image(url, content_type, w:, h:)
    return if url.blank?
    source = url.to_s.start_with?("//") ? "https:#{url}" : url
    format = content_type == "image/png" ? "png" : "jpg"
    mime = format == "png" ? "image/png" : "image/jpeg"
    image_url = images_api_url(source, w: w, h: h, fm: format)
    response = HTTParty.get(image_url)
    unless response.success?
      report_upstream_error("HTTP #{response.code}", context: "standard.site image fetch", status: response.code, url: image_url)
      return
    end
    [ response.body, mime ]
  rescue StandardError => e
    report_upstream_error(e, context: "standard.site image fetch")
    nil
  end

  # Builds a Contentful Images API URL, normalizing onto images.ctfassets.net — the downloads
  # host doesn't support transformations.
  # @return [String]
  def images_api_url(url, w:, h:, fm:)
    uri = URI.parse(url)
    uri.host = "images.ctfassets.net" if uri.host.to_s.end_with?("ctfassets.net")
    existing = URI.decode_www_form(uri.query || "").to_h
    uri.query = URI.encode_www_form(existing.merge("w" => w, "h" => h, "fit" => "fill", "fm" => fm))
    uri.to_s
  end

  # @return [Hash] JSON request headers with the bearer token.
  def auth_headers
    { "Content-Type" => "application/json", "Authorization" => "Bearer #{@access_jwt}" }
  end

  # Renders Markdown to plain text: no markup, decoded entities, collapsed whitespace.
  # Deliberately not MarkdownHelper#markdown_to_plain_text — this skips SmartyPants, and its
  # output feeds the content fingerprints, so changing it would re-sync every record.
  # @param text [String, nil] The Markdown.
  # @return [String, nil] The plain text, or nil when blank.
  def plain_text(text)
    return if text.blank?
    html = markdown.render(text.to_s)
    decoded = HTMLEntities.new.decode(Sanitize.fragment(html))
    decoded.gsub(/\s+/, " ").strip.presence
  end

  # @return [Redcarpet::Markdown] The reusable renderer.
  def markdown
    @markdown ||= Redcarpet::Markdown.new(Redcarpet::Render::HTML.new, **MarkdownHelper::EXTENSIONS)
  end

  # @param value [String, nil] A timestamp.
  # @return [String, nil] It as a UTC RFC3339 string with millisecond precision.
  def iso8601(value)
    return if value.blank?
    Time.parse(value.to_s).utc.iso8601(3)
  rescue StandardError
    nil
  end

  # @param str [String, nil] The string.
  # @param max [Integer] The maximum number of grapheme clusters.
  # @return [String, nil] The truncated string.
  def truncate_graphemes(str, max)
    return str if str.blank?
    graphemes = str.scan(/\X/)
    graphemes.length > max ? graphemes.first(max).join : str
  end
end
