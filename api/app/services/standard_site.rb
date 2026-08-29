require "digest"

# Publishes the blog to the AT Protocol as standard.site records. Contentful webhooks and the
# `standard_site:backfill` rake task start the sync:
#   - one site.standard.publication record for the site,
#   - one site.standard.document record for each published Article or Short,
#   - a record goes away when its post becomes unpublished or deleted.
#
# Redis caches a SHA-256 fingerprint of the content of each record. Thus the slow part (a
# cover-image blob upload and a putRecord) runs only when the content changes.
# Without Bluesky credentials, this service does nothing.
# @see https://standard.site
class StandardSite < ApplicationService
  include ContentfulConsumer
  include AtProto

  # The AT Protocol "sortable base32" alphabet. Each standard.site lexicon needs a TID for each
  # record key. Thus you cannot use a natural id as an rkey.
  # @see https://atproto.com/specs/tid
  TID_ALPHABET = AtProto::TID_ALPHABET

  # Makes a stable TID from a seed: the low 63 bits of its SHA-256 digest, in base32.
  # web's StandardSiteHelpers#document_rkey must use the same algorithm. If it does not, the AT
  # URI that it writes does not agree with the record that this class publishes.
  #
  # ⚠️ This is content-addressed and not time-ordered, on purpose: the same entry must always give
  # the same rkey. `.new_tid` from AtProto is the time-ordered one, for a record with no natural key.
  # @param seed [String]
  # @return [String] A 13-character TID.
  def self.tid(seed)
    encode_tid(Digest::SHA256.hexdigest(seed.to_s).to_i(16) & ((1 << 63) - 1))
  end

  # Makes a site.standard.theme.color#rgb value.
  # @param r [Integer] Red channel, 0-255.
  # @param g [Integer] Green channel, 0-255.
  # @param b [Integer] Blue channel, 0-255.
  # @return [Hash]
  def self.rgb(r, g, b)
    { "$type" => "site.standard.theme.color#rgb", "r" => r, "g" => g, "b" => b }
  end

  # The theme of the publication, for readers that show the site content in their own interface.
  # ⚠️ This is a copy of web's LIGHT-mode tokens in web/source/stylesheets/base/_props.scss. The
  # lexicon has no dark-mode equivalent. No test makes sure that the two agree.
  BASIC_THEME = {
    "$type" => "site.standard.theme.basic",
    "background" => rgb(255, 255, 255),       # white
    "foreground" => rgb(41, 41, 41),          # --color-text / --color-jet #292929
    "accent" => rgb(191, 2, 34),              # --color-firebrick #BF0222 (brand)
    "accentForeground" => rgb(250, 250, 250)  # --color-button-text / --color-cultured #FAFAFA
  }.freeze

  PUBLICATION_COLLECTION = "site.standard.publication"
  DOCUMENT_COLLECTION = "site.standard.document"
  # The publication is the singleton of the repo, at a stable TID made from the "self" seed.
  PUBLICATION_RKEY = tid("self")
  # The old rkey of the publication, from before the lexicon needed a TID. The backfill deletes it.
  LEGACY_PUBLICATION_RKEY = "self"
  DEFAULT_PDS_URL = AtProto::DEFAULT_PDS_URL
  # A DID stays the same for an account. Thus the cache holds it with no TTL.
  DID_CACHE_KEY = "standard_site:did"

  # A check on a Contentful sys.id before it becomes a record key.
  ENTRY_ID_PATTERN = /\A[a-zA-Z0-9._~:-]{1,512}\z/

  # Makes the at:// URI of the publication. This is the only source of the format. The sync
  # paths and the /api/standard-site endpoint use it.
  # @param did [String]
  # @return [String]
  def self.publication_uri(did)
    "at://#{did}/#{PUBLICATION_COLLECTION}/#{PUBLICATION_RKEY}"
  end

  # The article fields that the document builders need. The by-id query and the list query
  # share them.
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

  # @param credentials [BlueskyCredentials::Credentials] The pair that opens the session. The
  #   caller supplies it, thus the admin can check a new pair before the app stores it.
  def initialize(credentials: BlueskyCredentials.fetch)
    @handle = credentials.handle
    @app_password = credentials.app_password
  end

  # Syncs the document record of an entry. This method gets the entry again from the delivery
  # API. It does not read the webhook body, because that body has an unresolved cover-image link
  # and tags with no names. The retries give Contentful time to propagate the change. A draft
  # entry, a non-publishable entry, or an absent entry causes a delete.
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

  # Removes the document record of an unpublished or deleted entry. It is safe to do this more
  # than one time.
  # @param entry_id [String] The Contentful sys.id.
  # @return [Symbol] :deleted or :skipped.
  def delete_document(entry_id)
    return log_skip("document #{entry_id}", "no Bluesky credentials") unless valid_credentials?
    return log_skip("document #{entry_id}", "invalid entry id") unless eligible?(entry_id)
    return log_skip("document #{entry_id}", "could not authenticate with the PDS") unless create_session

    remove_document!(document_rkey(entry_id))
  end

  # Syncs the publication record again from the current site entry.
  # @return [Symbol] :synced, :unchanged, or :skipped.
  def sync_publication
    return log_skip("publication", "no Bluesky credentials") unless valid_credentials?
    return log_skip("publication", "could not authenticate with the PDS") unless create_session

    site = fetch_site
    return log_skip("publication", "no site data") if site.blank?
    do_sync_publication(site)
  end

  # Makes the full PDS repo agree with the published Contentful content. It syncs the
  # publication, adds a sync job for each publishable post, then deletes orphan document records.
  # This is the safety net for failed webhook deliveries, because Contentful does not send them
  # again. A Sidekiq worker must run, to do the queued jobs. The delete step runs immediately and
  # is safe, because it touches only records outside the published set.
  def backfill
    return log_skip("backfill", "no Bluesky credentials") unless valid_credentials?
    return log_skip("backfill", "could not authenticate with the PDS") unless create_session

    log("backfill starting")
    site = fetch_site
    return log_skip("backfill", "no site data") if site.blank?
    do_sync_publication(site)
    prune_legacy_publication

    items = fetch_all_articles
    # Stop before the delete step, thus a temporary fetch error cannot delete all the live records.
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

  # The DID of the account, from the Redis cache. If the cache is empty, this opens a session.
  # @return [String, nil] The DID, or nil if credentials are absent or the lookup fails.
  def did
    rescue_with(context: "standard.site DID") do
      cached = $redis.get(DID_CACHE_KEY)
      next cached if cached.present?
      next nil unless valid_credentials?
      create_session ? @did : nil
    end
  end

  # The handle that the owner entered. The Connected apps page names the account with it, and it
  # makes no request to get it.
  # @return [String, nil]
  attr_reader :handle

  # @return [Boolean] True if both Bluesky credentials are available.
  def valid_credentials?
    @handle.present? && @app_password.present?
  end

  # Tells if an account is connected, for the Connected apps page. This does not do a live
  # createSession, on purpose. The page shows this on each load. A PDS request here would put an
  # upstream failure in the path of the admin navigation.
  # @return [Boolean]
  def connected? = valid_credentials?

  # Checks a credential pair: it opens a session with the pair, then stores the pair if the
  # session opens. The same step caches the DID that the session finds.
  #
  # ⚠️ The fingerprint of the publication record must go away when the DID changes. Document
  # fingerprints include the at:// URI of the publication, which contains the DID, thus they
  # become invalid by themselves. The fingerprint of the publication record does not. An old one
  # would report :unchanged for all time and never sync to the new repo.
  # @return [Boolean] Whether the credentials opened a session and were stored.
  def connect!
    return false unless valid_credentials?

    previous_did = $redis.get(DID_CACHE_KEY)
    return false unless create_session

    $redis.del(fingerprint_key(PUBLICATION_COLLECTION, PUBLICATION_RKEY)) if previous_did.present? && previous_did != @did
    BlueskyCredentials.store(handle: @handle, app_password: @app_password)
    true
  end

  # Removes the stored credentials.
  #
  # ⚠️ This does not touch DID_CACHE_KEY. The DID is public data, not a credential, and its
  # records continue to exist. GET /api/standard-site supplies the verification <link> tags on
  # each page of the static site. If you clear the DID here, the next build removes those tags
  # from the full site with no message.
  # @return [void]
  def disconnect!
    BlueskyCredentials.clear
  end

  # Selects the posts that must have a document record: published Articles and Shorts.
  # This does not include Pages, on purpose.
  # @param posts [Array<Hash>] Decorated posts, with string keys.
  # @return [Array<Hash>]
  def publishable_posts(posts)
    Array(posts).select { |a| !a["draft"] && %w[Article Short].include?(a["entry_type"]) }
  end

  # Makes a site.standard.publication record. The caller supplies the icon and this method does
  # not upload it. Thus you can make the record for a fingerprint with no network use.
  # @param site [Hash] The decorated site, with string keys.
  # @param icon [Hash, String, nil] The uploaded blob, or a source descriptor for a
  #   fingerprint.
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

  # Makes a site.standard.document record. The caller supplies the cover image and this method
  # does not upload it. Thus you can make the record for a fingerprint with no network use.
  # @param post [Hash] A decorated post, with string keys.
  # @param publication_uri [String] The at:// URI of the publication.
  # @param cover_image [Hash, String, nil] The uploaded blob, or a source descriptor for a
  #   fingerprint.
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

  # The document record key of an entry. It comes from the sys.id only, thus sync, delete, and
  # prune calculate the same key. A delete has no post data.
  # @param entry_id [String] The Contentful sys.id.
  # @return [String] A 13-character TID.
  def document_rkey(entry_id)
    self.class.tid(entry_id)
  end

  # @param existing [Array<String>] The rkeys now in the document collection.
  # @param current [Array<String>] The rkeys that must stay.
  # @return [Array<String>] The rkeys on the PDS that are no longer current.
  def rkeys_to_prune(existing, current)
    Array(existing) - Array(current)
  end

  # A content fingerprint for the document record of a post. It uses the same builder as the
  # synced record, but the source URL of the cover image replaces the blob. Thus a different
  # image changes the fingerprint with no network request.
  # @param post [Hash] A decorated post, with string keys.
  # @param publication_uri [String] The at:// URI of the publication.
  # @return [String]
  def document_fingerprint(post, publication_uri)
    record = build_document_record(post, publication_uri, cover_image: cover_source(post["cover_image"]))
    Digest::SHA256.hexdigest(record.to_json)
  end

  # A content fingerprint for the publication record.
  # @param site [Hash] The decorated site, with string keys.
  # @return [String]
  def publication_fingerprint(site)
    record = build_publication_record(site, icon: cover_source(site["logo"]))
    Digest::SHA256.hexdigest(record.to_json)
  end

  private

  # Writes a one-line operation message at info level and returns `result`. Thus a caller can
  # write `return log(msg, :result)`.
  # @return The same result.
  def log(message, result = nil)
    Rails.logger.info("standard.site: #{message}")
    result
  end

  # Writes why an operation did not run and returns :skipped.
  def log_skip(subject, reason)
    log("#{subject} skipped (#{reason})", :skipped)
  end

  # @param entry_id [String, nil]
  # @return [Boolean] True if the id can be an AT Protocol record key.
  def eligible?(entry_id)
    entry_id.present? && ENTRY_ID_PATTERN.match?(entry_id.to_s)
  end

  # A stable descriptor of the source of an image. It replaces an uploaded blob in a fingerprint.
  # A Contentful URL contains a version, thus a new asset changes the descriptor.
  # @param image [Hash, nil] An object with 'url' and 'content_type' keys.
  # @return [String, nil]
  def cover_source(image)
    url = image&.dig("url")
    return if url.blank?
    "#{url}|#{image['content_type']}"
  end

  # Syncs the publication record. If the fingerprint does not change, the upload and the
  # putRecord do not run.
  # @param site [Hash] The decorated site, with string keys.
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

  # Deletes the publication record at the old "self" rkey, which the lexicon does not accept.
  # It is safe to run this on each backfill.
  def prune_legacy_publication
    return if PUBLICATION_RKEY == LEGACY_PUBLICATION_RKEY
    delete_record(PUBLICATION_COLLECTION, LEGACY_PUBLICATION_RKEY)
  end

  # Syncs one document record. If the fingerprint does not change, the cover-image upload and
  # the putRecord do not run.
  # @param post [Hash] A decorated post, with string keys.
  # @param rkey [String] The record key.
  # @param publication_uri [String] The at:// URI of the publication.
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

  # Deletes a document record by rkey and removes its fingerprint.
  #
  # ⚠️ This removes the fingerprint only after the delete is successful. If you remove it after
  # a failed delete, the record stays on the PDS and nothing can find the difference. The job
  # then returns as if it was successful.
  # @return [Symbol] :deleted, or :error when the PDS rejected the delete.
  def remove_document(rkey)
    return log("document #{rkey} deleteRecord failed", :error) unless delete_record(DOCUMENT_COLLECTION, rkey)

    forget_fingerprint(rkey)
    log("document #{rkey} deleted", :deleted)
  end

  # The same as remove_document, but it raises on failure, thus Sidekiq does the job again.
  #
  # ⚠️ The prune path of the backfill uses remove_document, on purpose. One record that the app
  # cannot reach must not stop a full reconciliation run.
  # @return [Symbol] :deleted.
  def remove_document!(rkey)
    result = remove_document(rkey)
    raise "could not delete document #{rkey} from the PDS" if result == :error

    result
  end

  # --- Contentful (delivery API) ------------------------------------------------------

  # @param entry_id [String] The Contentful sys.id.
  # @return [Hash, nil] The raw article item with symbol keys, or nil if it is absent or the
  #   request fails.
  def fetch_article(entry_id)
    query_contentful(ARTICLE_QUERY, { id: entry_id })&.dig(:articles, :items)&.first
  end

  # @return [Hash, nil] The decorated site with string keys, or nil if it is absent or the
  #   request fails.
  def fetch_site
    item = query_contentful(SITE_QUERY)&.dig(:sites, :items)&.first
    item && decorate_site(item)
  end

  # Reads the full article collection, one page at a time. It is strict, because the sync must
  # never use an incomplete set.
  # @return [Array<Hash>, nil] All the raw article items, or nil if one page fails.
  def fetch_all_articles
    contentful.paginate(ARTICLES_LIST_QUERY, collection: :articles, strict: true)
  end

  # @return [Hash, nil] The `data` of the query, or nil if there is no configuration or the
  #   request fails.
  def query_contentful(query, variables = nil)
    contentful.query(query, variables)
  end

  # Changes a raw GraphQL article item into the string-key shape that the record builders need.
  # ArticleAttributes keeps draft, entry_type, and path the same as in the other parts of the app.
  # @param item [Hash] A raw article item with symbol keys.
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

  # The tags of the article for the record. It joins the concept ids from GraphQL to their names.
  # It removes each concept with a name that it cannot find.
  # @param item [Hash] A raw article item with symbol keys.
  # @return [Array<Hash>] { "id", "name" } hashes.
  def article_tags(item)
    Array(item.dig(:contentfulMetadata, :concepts)).filter_map do |concept|
      name = taxonomy_names[concept[:id].to_s]
      { "id" => concept[:id], "name" => name } if name.present?
    end
  end

  # Concept id => name for the full taxonomy. The app gets it one time for each sync. It is empty
  # if the taxonomy is not available.
  # @return [Hash{String=>String}]
  def taxonomy_names
    @taxonomy_names ||= TaxonomyConcepts.new.names || {}
  end

  # @param item [Hash] A raw site item with symbol keys.
  # @return [Hash] The site with string keys, for the publication builder.
  def decorate_site(item)
    logo = item[:logo]
    {
      "title" => item[:title],
      "meta_description" => item[:metaDescription],
      "logo" => logo && { "url" => logo[:url], "content_type" => logo[:contentType] }
    }
  end

  # --- Fingerprint cache (the Redis of this app; the web app does not read it) --------

  # The Redis key for the fingerprint of a record. The collection is part of the key, thus a
  # document and the publication cannot have the same rkey.
  def fingerprint_key(collection, rkey)
    "standard_site:fingerprint:#{collection}:#{rkey}"
  end

  # @return [String, nil] The fingerprint from the last sync, or nil if it is absent.
  def stored_fingerprint(collection, rkey)
    return unless defined?($redis) && $redis
    $redis.get(fingerprint_key(collection, rkey))
  end

  # Stores the fingerprint of a record with no TTL. It stays after each sync.
  def store_fingerprint(collection, rkey, value)
    return unless defined?($redis) && $redis
    $redis.set(fingerprint_key(collection, rkey), value)
  end

  # Removes the cached fingerprint of a deleted record, thus it syncs again if it comes back.
  def forget_fingerprint(rkey)
    return unless defined?($redis) && $redis
    $redis.del(fingerprint_key(DOCUMENT_COLLECTION, rkey))
  end

  # @return [String] The production site root, with no slash at the end.
  def publication_url
    ENV["SITE_URL"].to_s.chomp("/")
  end

  # Changes a post path into the canonical page URL. Thus document verification gets the page
  # that has the <link> tag.
  # @param path [String] The decorated post path.
  # @return [String, nil]
  def document_path(path)
    return if path.blank?
    cleaned = path.to_s.sub(/index\.html\z/, "")
    cleaned.start_with?("/") ? cleaned : "/#{cleaned}"
  end

  # --- PDS (AT Protocol) --------------------------------------------------------------

  # The name of this client in each log line and each error report of AtProto.
  # @return [String]
  def at_proto_label = "standard.site"

  # Opens a session with the PDS and caches the DID.
  #
  # ⚠️ The PDS lexicons here are site.standard.*, which a PDS does not know. Thus each write sends
  # `validate: false`, which is the default of `AtProto#put_record`.
  # @return [Boolean] True if a session is available.
  def create_session
    return false unless valid_credentials?
    return false unless open_session(handle: @handle, app_password: @app_password)

    $redis.set(DID_CACHE_KEY, @did) if @did.present? && defined?($redis) && $redis
    true
  end

  # Deletes each document record with an rkey that is not in the current set.
  # @param current_rkeys [Array<String>] The rkeys that must stay.
  # @return [Integer] The number of records that it deleted.
  def prune_documents(current_rkeys)
    stale = rkeys_to_prune(list_record_rkeys(DOCUMENT_COLLECTION), current_rkeys)
    stale.count { |rkey| remove_document(rkey) == :deleted }
  end

  # @param collection [String] The collection to list.
  # @return [Array<String>] All the rkeys in it. The cursor gives one page at a time.
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

  # Changes Markdown into plain text: no markup, decoded entities, and one space between words.
  # This is not MarkdownHelper#markdown_to_plain_text, on purpose. It does not use SmartyPants.
  # Its output goes into the content fingerprints, thus a change here syncs each record again.
  # @param text [String, nil] The Markdown.
  # @return [String, nil] The plain text, or nil when blank.
  def plain_text(text)
    return if text.blank?
    html = markdown.render(text.to_s)
    decoded = HTMLEntities.new.decode(Sanitize.fragment(html))
    decoded.gsub(/\s+/, " ").strip.presence
  end

  # @return [Redcarpet::Markdown] The shared renderer.
  def markdown
    @markdown ||= Redcarpet::Markdown.new(Redcarpet::Render::HTML.new, **MarkdownHelper::EXTENSIONS)
  end

  # @param value [String, nil] A timestamp.
  # @return [String, nil] The timestamp as a UTC RFC3339 string with milliseconds.
  def iso8601(value)
    return if value.blank?
    Time.parse(value.to_s).utc.iso8601(3)
  rescue StandardError
    nil
  end
end
