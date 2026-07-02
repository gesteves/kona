require "digest"

# Publishes the blog to the AT Protocol as standard.site records.
# @see https://standard.site
#
# This is the api-side, event-driven successor to the web build's StandardSite. It is
# driven by Contentful webhooks (see Api::WebhooksController) plus the
# `standard_site:backfill` rake task, rather than running on every static build:
#   - one site.standard.publication record (rkey "self") tracks the site,
#   - one site.standard.document record per published post (rkey = a TID derived
#     deterministically from the post's Contentful sys.id) tracks each Article/Short,
#   - records are pruned when a post is unpublished/deleted (per-event) or no longer
#     maps to a published post (backfill).
#
# To avoid redundant work, a SHA-256 fingerprint of each record's content is cached in
# Redis (shared with the web app — the keys carry over), and a record is only
# re-uploaded (the expensive part — a cover-image blob upload plus a putRecord) when its
# fingerprint changes.
#
# Everything no-ops when the Bluesky credentials are absent, so a misconfigured or
# credential-free environment simply doesn't publish.
class StandardSite < ApplicationService
  # AT Protocol "sortable base32" alphabet, used to encode TIDs. Both standard.site
  # lexicons require every record key to be a TID — a 13-character base32-sortable
  # identifier — so neither the publication's "self" nor a Contentful sys.id can be used
  # as the rkey directly.
  # @see https://atproto.com/specs/tid
  TID_ALPHABET = "234567abcdefghijklmnopqrstuvwxyz"

  # Derives a stable, valid 13-character TID from a seed string: the low 63 bits of the
  # seed's SHA-256 digest become the TID's value (the top bit stays 0, as a TID
  # requires). Deterministic, so the same seed always maps to the same record key.
  # ⚠️ web's StandardSiteHelpers#document_rkey must use the identical algorithm for the
  # document seed, or the <link rel="site.standard.document"> AT URI won't match the
  # published record.
  # @param seed [String]
  # @return [String] A valid TID.
  def self.tid(seed)
    value = Digest::SHA256.hexdigest(seed.to_s).to_i(16) & ((1 << 63) - 1)
    encoded = +""
    while value.positive?
      encoded = TID_ALPHABET[value % 32] + encoded
      value /= 32
    end
    encoded.rjust(13, TID_ALPHABET[0])
  end

  PUBLICATION_COLLECTION = "site.standard.publication"
  DOCUMENT_COLLECTION = "site.standard.document"
  # The publication is the repo's singleton, historically at rkey "self"; the lexicon now
  # requires a TID, so it lives at a stable TID derived from that "self" seed.
  PUBLICATION_RKEY = tid("self")
  # The publication used to live at this literal rkey; backfill prunes the legacy record.
  LEGACY_PUBLICATION_RKEY = "self"
  DEFAULT_PDS_URL = "https://bsky.social"
  # The DID is stable for an account, so it's cached without a TTL and reused by the
  # /api/standard-site endpoint the web build reads.
  DID_CACHE_KEY = "standard_site:did"

  # Sanity guard for a Contentful sys.id before it's turned into a record key.
  ENTRY_ID_PATTERN = /\A[a-zA-Z0-9._~:-]{1,512}\z/

  # Builds the publication's at:// URI for a DID. Single source of truth for the format,
  # shared by the sync paths and the /api/standard-site endpoint.
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
    contentfulMetadata { tags { id name } }
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

  def initialize
    @handle = ENV["BLUESKY_HANDLE"]
    @app_password = ENV["BLUESKY_APP_PASSWORD"]
    @pds_url = (ENV["BLUESKY_PDS_URL"].presence || DEFAULT_PDS_URL).chomp("/")
  end

  # Syncs the document record for an article/short entry, identified by its Contentful
  # entry id. The webhook body isn't trusted for content (its cover image is an
  # unresolved link and its tags lack names), so the resolved entry is re-fetched from
  # the delivery API — with retries to absorb its brief post-publish propagation lag.
  # A draft / non-publishable / vanished entry is treated as a delete.
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
    if post.blank? || publishable_posts([post]).empty?
      log("entry #{entry_id} is not a publishable post; removing any document record")
      return remove_document(entry_id)
    end

    publication_uri = self.class.publication_uri(@did)
    do_sync_document(post, document_rkey(entry_id), publication_uri)
  end

  # Removes the document record for an unpublished/deleted entry (idempotent: deleting a
  # record that doesn't exist is a harmless no-op).
  # @param entry_id [String] The Contentful sys.id.
  # @return [Symbol] :deleted or :skipped.
  def delete_document(entry_id)
    return log_skip("document #{entry_id}", "no Bluesky credentials") unless valid_credentials?
    return log_skip("document #{entry_id}", "invalid entry id") unless eligible?(entry_id)
    return log_skip("document #{entry_id}", "could not authenticate with the PDS") unless create_session

    remove_document(document_rkey(entry_id))
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

  # Reconciles the whole PDS repo with the published Contentful corpus: syncs the
  # publication inline, enqueues a background sync job for every publishable post, then
  # prunes orphaned document records. This is the safety net for any webhook delivery that
  # failed (Contentful does not retry). The per-post syncs run as StandardSiteSyncJob jobs
  # so a large corpus fans out across the worker (and each is individually retried) instead
  # of blocking the task serially; a Sidekiq worker must be running to drain them. Pruning
  # stays inline and is safe to run immediately: it only deletes records outside `current`
  # (the full published set), which the enqueued jobs never touch.
  def backfill
    return log_skip("backfill", "no Bluesky credentials") unless valid_credentials?
    return log_skip("backfill", "could not authenticate with the PDS") unless create_session

    log("backfill starting")
    site = fetch_site
    return log_skip("backfill", "no site data") if site.blank?
    do_sync_publication(site)
    prune_legacy_publication

    items = fetch_all_articles
    # Bail before pruning if the article fetch failed, so a transient error can never
    # prune live records down to nothing.
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

  # The account's DID, for the /api/standard-site endpoint the web build reads. Served
  # from the permanent Redis cache, resolving (and caching) a session on demand when it's
  # absent. Returns nil when credentials are missing or resolution fails.
  # @return [String, nil]
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

  # Selects the posts that should have a document record: published (non-draft)
  # articles and shorts. Pages are intentionally excluded.
  # @param posts [Array<Hash>] Decorated posts (string keys).
  # @return [Array<Hash>]
  def publishable_posts(posts)
    Array(posts).select { |a| !a["draft"] && %w[Article Short].include?(a["entry_type"]) }
  end

  # Builds a site.standard.publication record from the site data.
  # The icon blob is supplied by the caller (rather than uploaded here) so the
  # record can be built cheaply for fingerprinting without touching the network.
  # @param site [Hash] Decorated site (string keys).
  # @param icon [Hash, String, nil] The uploaded icon blob, or a source
  #   descriptor when building a fingerprint.
  # @return [Hash]
  def build_publication_record(site, icon: nil)
    record = {
      "$type" => PUBLICATION_COLLECTION,
      "url" => publication_url,
      "name" => truncate_graphemes(site["title"].to_s, 500),
      "preferences" => { "showInDiscover" => true }
    }
    description = plain_text(site["meta_description"])
    record["description"] = truncate_graphemes(description, 3000) if description.present?
    record["icon"] = icon if icon.present?
    record
  end

  # Builds a site.standard.document record for a post.
  # The cover image blob is supplied by the caller (rather than uploaded here) so
  # the record can be built cheaply for fingerprinting without touching the network.
  # @param post [Hash] A decorated post (string keys).
  # @param publication_uri [String] The publication's at:// URI.
  # @param cover_image [Hash, String, nil] The uploaded cover image blob, or a
  #   source descriptor when building a fingerprint.
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

    text = plain_text([post["intro"], post["body"]].reject(&:blank?).join("\n\n"))
    record["textContent"] = text if text.present?

    tags = Array(post.dig("contentful_metadata", "tags")).map { |t| t["name"] }.compact_blank
    record["tags"] = tags if tags.present?

    record["coverImage"] = cover_image if cover_image.present?
    record
  end

  # The document record key for a Contentful entry: a TID derived deterministically
  # from the sys.id, so every operation (sync, delete, prune) computes the same key
  # from the entry id alone — a delete has no post data to work from. The post's real
  # publish time lives in the record's publishedAt field, so nothing depends on
  # decoding a meaningful timestamp out of the key.
  # @param entry_id [String] The Contentful sys.id.
  # @return [String] A valid 13-character TID.
  def document_rkey(entry_id)
    self.class.tid(entry_id)
  end

  # Returns the rkeys that exist on the PDS but are not in the current set.
  # @param existing [Array<String>] rkeys currently in the document collection.
  # @param current [Array<String>] rkeys that should remain.
  # @return [Array<String>]
  def rkeys_to_prune(existing, current)
    Array(existing) - Array(current)
  end

  # A content fingerprint for a post's document record. Built from the same
  # builder as the synced record, with the cover image represented by its source
  # URL instead of the uploaded blob, so any change to the record's content
  # (including swapping the cover image) changes the fingerprint without needing
  # a network round trip to compute it.
  # @param post [Hash] A decorated post (string keys).
  # @param publication_uri [String] The publication's at:// URI.
  # @return [String]
  def document_fingerprint(post, publication_uri)
    record = build_document_record(post, publication_uri, cover_image: cover_source(post["cover_image"]))
    Digest::SHA256.hexdigest(record.to_json)
  end

  # A content fingerprint for the publication record. Built from the same builder
  # as the synced record, with the icon represented by its source descriptor.
  # @param site [Hash] Decorated site (string keys).
  # @return [String]
  def publication_fingerprint(site)
    record = build_publication_record(site, icon: cover_source(site["logo"]))
    Digest::SHA256.hexdigest(record.to_json)
  end

  private

  # Logs a one-line standard.site operation message at info level (visible in production
  # logs), and returns the given value so callers can `return log(msg, :result)`.
  # @return the passed-through result.
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

  # A stable descriptor of an image's source, used in place of an uploaded blob
  # when fingerprinting. The Contentful URL carries a version cache-buster, so a
  # replaced asset yields a different descriptor.
  # @param image [Hash, nil] An object with 'url' and 'content_type' keys.
  # @return [String, nil]
  def cover_source(image)
    url = image&.dig("url")
    return if url.blank?
    "#{url}|#{image['content_type']}"
  end

  # Syncs the publication record, skipping the upload + putRecord when its
  # content fingerprint is unchanged since the last run.
  # @param site [Hash] Decorated site (string keys).
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

  # One-time migration cleanup: the publication used to live at rkey "self", which the
  # lexicon no longer accepts (it must be a TID). Deletes that legacy record so the repo
  # doesn't carry a stale, invalid publication. Idempotent — deleting a record that's
  # already gone is a harmless no-op, so this can run on every backfill.
  def prune_legacy_publication
    return if PUBLICATION_RKEY == LEGACY_PUBLICATION_RKEY
    delete_record(PUBLICATION_COLLECTION, LEGACY_PUBLICATION_RKEY)
  end

  # Syncs a single document record, skipping the cover-image upload + putRecord
  # when its content fingerprint is unchanged since the last run.
  # @param post [Hash] A decorated post (string keys).
  # @param rkey [String] The record key (the post's sys.id).
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
  # @return [Symbol] :deleted.
  def remove_document(rkey)
    delete_record(DOCUMENT_COLLECTION, rkey)
    forget_fingerprint(rkey)
    log("document #{rkey} deleted", :deleted)
  end

  # --- Contentful (delivery API) ------------------------------------------------------

  # @param entry_id [String]
  # @return [Hash, nil] The raw (symbolized) article item, or nil if not found/failed.
  def fetch_article(entry_id)
    query_contentful(ARTICLE_QUERY, { id: entry_id })&.dig(:articles, :items)&.first
  end

  # @return [Hash, nil] The decorated site (string keys), or nil if not found/failed.
  def fetch_site
    item = query_contentful(SITE_QUERY)&.dig(:sites, :items)&.first
    item && decorate_site(item)
  end

  # Pages through the whole article collection. Strict: the sync must never act on a
  # partial corpus, so any failed page aborts the whole fetch.
  # @return [Array<Hash>, nil] All raw article items, or nil if any page request failed.
  def fetch_all_articles
    contentful.paginate(ARTICLES_LIST_QUERY, collection: :articles, strict: true)
  end

  # Runs a Contentful GraphQL query and returns its `data` hash, or nil when the API
  # isn't configured or the request failed.
  def query_contentful(query, variables = nil)
    contentful.query(query, variables)
  end

  def contentful
    @contentful ||= ContentfulClient.new(self.class.name)
  end

  # Maps a raw (symbolized) GraphQL article item to the string-keyed shape the record
  # builders expect. The shared derivation (ArticleAttributes) keeps draft/entry_type/path
  # consistent with Articles#decorate and the web build.
  # @param item [Hash]
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
        "tags" => Array(item.dig(:contentfulMetadata, :tags)).map { |t| { "id" => t[:id], "name" => t[:name] } }
      }
    }
  end

  # @param item [Hash] A raw (symbolized) GraphQL site item.
  # @return [Hash] String-keyed site for the publication builder.
  def decorate_site(item)
    logo = item[:logo]
    {
      "title" => item[:title],
      "meta_description" => item[:metaDescription],
      "logo" => logo && { "url" => logo[:url], "content_type" => logo[:contentType] }
    }
  end

  # --- Fingerprint cache (this app's Redis; not read by the web app) ------------------

  # The Redis key under which a record's content fingerprint is cached. Scoped by
  # collection so a document and the publication can never collide on rkey.
  def fingerprint_key(collection, rkey)
    "standard_site:fingerprint:#{collection}:#{rkey}"
  end

  # @return [String, nil] The last-synced fingerprint, or nil if none/no Redis.
  def stored_fingerprint(collection, rkey)
    return unless defined?($redis) && $redis
    $redis.get(fingerprint_key(collection, rkey))
  end

  # Persists a record's content fingerprint (no TTL — it outlives any single sync).
  def store_fingerprint(collection, rkey, value)
    return unless defined?($redis) && $redis
    $redis.set(fingerprint_key(collection, rkey), value)
  end

  # Drops a document record's cached fingerprint, so a pruned record doesn't leave a
  # stale entry behind (and would re-sync if it ever reappears).
  def forget_fingerprint(rkey)
    return unless defined?($redis) && $redis
    $redis.del(fingerprint_key(DOCUMENT_COLLECTION, rkey))
  end

  # The publication's base URL: the production site root, without a trailing slash.
  # @return [String]
  def publication_url
    ENV["SITE_URL"].to_s.chomp("/")
  end

  # Converts a post path into a document path that resolves to the exact canonical page
  # URL, so document verification fetches the page that actually carries the <link> tag.
  # The decorated path already lacks index.html; this just guards the leading slash and
  # strips any trailing index.html for safety.
  # @param path [String]
  # @return [String, nil]
  def document_path(path)
    return if path.blank?
    cleaned = path.to_s.sub(/index\.html\z/, "")
    cleaned.start_with?("/") ? cleaned : "/#{cleaned}"
  end

  # --- PDS (AT Protocol) --------------------------------------------------------------

  # Authenticates with the PDS via an app password and resolves the DID and the
  # repo's PDS service endpoint. Caches the DID for the /api/standard-site endpoint.
  # @return [Boolean] true if a usable session was established.
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

  # Extracts the #atproto_pds service endpoint from a DID document, if present.
  # @param doc [Hash, nil]
  # @return [String, nil]
  def pds_endpoint_from_did_doc(doc)
    return if doc.blank?
    service = Array(doc["service"]).find { |s| s["id"].to_s.end_with?("#atproto_pds") }
    service&.dig("serviceEndpoint")&.chomp("/")
  end

  # Creates or updates a record (idempotent on repo+collection+rkey).
  # validate:false because the PDS doesn't know the site.standard.* lexicons.
  # @return [Boolean] true on success.
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

  # Deletes any document records whose rkey is not in the current set.
  # @param current_rkeys [Array<String>]
  # @return [Integer] the number of records pruned.
  def prune_documents(current_rkeys)
    stale = rkeys_to_prune(list_record_rkeys(DOCUMENT_COLLECTION), current_rkeys)
    stale.each { |rkey| remove_document(rkey) }
    stale.size
  end

  # Lists every rkey in a collection, paging through the cursor.
  # @param collection [String]
  # @return [Array<String>]
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
  def delete_record(collection, rkey)
    HTTParty.post(
      "#{@service_url}/xrpc/com.atproto.repo.deleteRecord",
      body: { repo: @did, collection: collection, rkey: rkey }.to_json,
      headers: auth_headers
    )
  end

  # Downloads a resized copy of an image and uploads it to the PDS as a blob.
  # Returns nil (and the field is omitted) on any failure or when there's no
  # session, which also keeps the pure record builders network-free in tests.
  # @return [Hash, nil] The blob object, or nil.
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

  # Fetches a resized image as raw bytes via Contentful's Images API, keeping blobs
  # comfortably under 1MB. Image fetches happen only on publish (rare), so hitting
  # Contentful directly is fine — no CDN indirection needed.
  # @return [Array(String, String), nil] [bytes, mime_type] or nil.
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
    [response.body, mime]
  rescue StandardError => e
    report_upstream_error(e, context: "standard.site image fetch")
    nil
  end

  # Builds a Contentful Images API URL, normalizing to the images.ctfassets.net
  # host (the downloads host doesn't support image transformations).
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

  # Renders Markdown to plain text (no markup, decoded entities, collapsed whitespace).
  # Returns nil if blank.
  # @param text [String, nil]
  # @return [String, nil]
  def plain_text(text)
    return if text.blank?
    html = markdown.render(text.to_s)
    decoded = HTMLEntities.new.decode(Sanitize.fragment(html))
    decoded.gsub(/\s+/, " ").strip.presence
  end

  # @return [Redcarpet::Markdown] A reusable Markdown renderer.
  def markdown
    @markdown ||= Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new,
      fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true
    )
  end

  # Parses a timestamp into a UTC RFC3339 string with millisecond precision.
  # @param value [String, nil]
  # @return [String, nil]
  def iso8601(value)
    return if value.blank?
    Time.parse(value.to_s).utc.iso8601(3)
  rescue StandardError
    nil
  end

  # Truncates a string to a maximum number of grapheme clusters.
  # @param str [String, nil]
  # @param max [Integer]
  # @return [String, nil]
  def truncate_graphemes(str, max)
    return str if str.blank?
    graphemes = str.scan(/\X/)
    graphemes.length > max ? graphemes.first(max).join : str
  end
end
