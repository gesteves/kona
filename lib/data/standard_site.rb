require 'httparty'
require 'digest'
require 'json'
require 'uri'
require 'time'
require 'redcarpet'
require 'sanitize'
require 'htmlentities'
require 'active_support/all'

# Publishes the blog to the AT Protocol as standard.site records.
# @see https://standard.site
#
# In production only (ENV['CONTEXT'] == 'production'), this:
#   - creates/updates one site.standard.publication record (rkey "self"),
#   - creates/updates one site.standard.document record per published post
#     (rkey = the post's Contentful sys.id),
#   - prunes any site.standard.document records that no longer correspond to a
#     currently-published post (handles unpublished/deleted posts and the rare
#     case of a sys.id changing), and
#   - writes data/standard_site.json so the build can emit the on-site
#     verification endpoints (the .well-known endpoint and <link> tags).
#
# The build runs hourly but content rarely changes, so the sync is incremental:
# a SHA-256 fingerprint of each record's content is cached in Redis, and a
# record is only re-uploaded (the expensive part — a cover-image blob upload
# plus a putRecord) when its fingerprint changes. A run with no content changes
# makes no putRecord/uploadBlob calls at all.
#
# Local `middleman build` and Netlify deploy-preview/branch-deploy builds never
# touch the PDS: save_data returns before any network call and writes no data
# file, so the verification templates simply omit the standard.site markup.
class StandardSite
  PUBLICATION_COLLECTION = 'site.standard.publication'
  DOCUMENT_COLLECTION = 'site.standard.document'
  PUBLICATION_RKEY = 'self'
  DEFAULT_PDS_URL = 'https://bsky.social'

  # Valid AT Protocol record-key characters (a subset is plenty for sys.ids).
  # @see https://atproto.com/specs/record-key
  RKEY_PATTERN = /\A[a-zA-Z0-9._~:-]{1,512}\z/

  def initialize
    @handle = ENV['BLUESKY_HANDLE']
    @app_password = ENV['BLUESKY_APP_PASSWORD']
    @pds_url = (ENV['BLUESKY_PDS_URL'].presence || DEFAULT_PDS_URL).chomp('/')
  end

  # Syncs records to the PDS and writes data/standard_site.json.
  # No-ops outside production so local and preview builds never touch the PDS.
  def save_data
    return unless ENV['CONTEXT'] == 'production'
    return unless valid_credentials?
    return unless create_session

    site = load_json('data/site.json')
    articles = load_json('data/articles.json')
    # Bail before any write if the upstream content import didn't produce data,
    # so a partial import can never prune live records down to nothing.
    return if site.blank? || articles.blank?

    publication_uri = "at://#{@did}/#{PUBLICATION_COLLECTION}/#{PUBLICATION_RKEY}"
    sync_publication(site)

    documents = {}
    publishable_posts(articles).each do |post|
      rkey = post.dig('sys', 'id')
      next if rkey.blank? || !RKEY_PATTERN.match?(rkey)
      # The URI is deterministic, so the verification map is always complete even
      # when the record itself is left untouched as unchanged.
      documents[rkey] = "at://#{@did}/#{DOCUMENT_COLLECTION}/#{rkey}"
      sync_document(post, rkey, publication_uri)
    end

    # Remove any document records that no longer map to a published post.
    prune_documents(documents.keys)

    File.write('data/standard_site.json', {
      did: @did,
      publication_uri: publication_uri,
      documents: documents
    }.to_json)
  rescue StandardError => e
    puts "Error syncing standard.site records: #{e.message}" if ENV['DEBUG']
    nil
  end

  # @return [Boolean] true if both Bluesky credentials are present.
  def valid_credentials?
    @handle.present? && @app_password.present?
  end

  # Selects the posts that should have a document record: published (non-draft)
  # articles and shorts. Pages are intentionally excluded.
  # @param articles [Array<Hash>] Processed articles from data/articles.json.
  # @return [Array<Hash>]
  def publishable_posts(articles)
    Array(articles).select { |a| !a['draft'] && %w[Article Short].include?(a['entry_type']) }
  end

  # Builds a site.standard.publication record from the site data.
  # The icon blob is supplied by the caller (rather than uploaded here) so the
  # record can be built cheaply for fingerprinting without touching the network.
  # @param site [Hash] Parsed data/site.json (string keys).
  # @param icon [Hash, String, nil] The uploaded icon blob, or a source
  #   descriptor when building a fingerprint.
  # @return [Hash]
  def build_publication_record(site, icon: nil)
    record = {
      '$type' => PUBLICATION_COLLECTION,
      'url' => publication_url,
      'name' => truncate_graphemes(site['title'].to_s, 500),
      'preferences' => { 'showInDiscover' => true }
    }
    description = plain_text(site['meta_description'])
    record['description'] = truncate_graphemes(description, 3000) if description.present?
    record['icon'] = icon if icon.present?
    record
  end

  # Builds a site.standard.document record for a post.
  # The cover image blob is supplied by the caller (rather than uploaded here) so
  # the record can be built cheaply for fingerprinting without touching the network.
  # @param post [Hash] A processed article (string keys).
  # @param publication_uri [String] The publication's at:// URI.
  # @param cover_image [Hash, String, nil] The uploaded cover image blob, or a
  #   source descriptor when building a fingerprint.
  # @return [Hash]
  def build_document_record(post, publication_uri, cover_image: nil)
    record = {
      '$type' => DOCUMENT_COLLECTION,
      'site' => publication_uri,
      'title' => truncate_graphemes(post['title'].to_s, 500),
      'publishedAt' => iso8601(post['published_at'])
    }
    path = document_path(post['path'])
    record['path'] = path if path.present?
    updated = iso8601(post['updated_at'])
    record['updatedAt'] = updated if updated.present?

    description = plain_text(post['summary'].presence || post['intro'])
    record['description'] = truncate_graphemes(description, 3000) if description.present?

    text = plain_text([post['intro'], post['body']].reject(&:blank?).join("\n\n"))
    record['textContent'] = text if text.present?

    tags = Array(post.dig('contentful_metadata', 'tags')).map { |t| t['name'] }.compact_blank
    record['tags'] = tags if tags.present?

    record['coverImage'] = cover_image if cover_image.present?
    record
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
  # @param post [Hash] A processed article (string keys).
  # @param publication_uri [String] The publication's at:// URI.
  # @return [String]
  def document_fingerprint(post, publication_uri)
    record = build_document_record(post, publication_uri, cover_image: cover_source(post['cover_image']))
    Digest::SHA256.hexdigest(record.to_json)
  end

  # A content fingerprint for the publication record. Built from the same builder
  # as the synced record, with the icon represented by its source descriptor.
  # @param site [Hash] Parsed data/site.json (string keys).
  # @return [String]
  def publication_fingerprint(site)
    record = build_publication_record(site, icon: cover_source(site['logo']))
    Digest::SHA256.hexdigest(record.to_json)
  end

  private

  # A stable descriptor of an image's source, used in place of an uploaded blob
  # when fingerprinting. The Contentful URL carries a version cache-buster, so a
  # replaced asset yields a different descriptor.
  # @param image [Hash, nil] An object with 'url' and 'content_type' keys.
  # @return [String, nil]
  def cover_source(image)
    url = image&.dig('url')
    return if url.blank?
    "#{url}|#{image['content_type']}"
  end

  # Syncs the publication record, skipping the upload + putRecord when its
  # content fingerprint is unchanged since the last run.
  # @param site [Hash] Parsed data/site.json (string keys).
  def sync_publication(site)
    fingerprint = publication_fingerprint(site)
    return if fingerprint == stored_fingerprint(PUBLICATION_COLLECTION, PUBLICATION_RKEY)
    icon = upload_image_blob(site.dig('logo', 'url'), site.dig('logo', 'content_type'), w: 512, h: 512)
    record = build_publication_record(site, icon: icon)
    if put_record(PUBLICATION_COLLECTION, PUBLICATION_RKEY, record)
      store_fingerprint(PUBLICATION_COLLECTION, PUBLICATION_RKEY, fingerprint)
    end
  end

  # Syncs a single document record, skipping the cover-image upload + putRecord
  # when its content fingerprint is unchanged since the last run.
  # @param post [Hash] A processed article (string keys).
  # @param rkey [String] The record key (the post's sys.id).
  # @param publication_uri [String] The publication's at:// URI.
  def sync_document(post, rkey, publication_uri)
    fingerprint = document_fingerprint(post, publication_uri)
    return if fingerprint == stored_fingerprint(DOCUMENT_COLLECTION, rkey)
    cover = upload_image_blob(post.dig('cover_image', 'url'), post.dig('cover_image', 'content_type'), w: 1200, h: 630)
    record = build_document_record(post, publication_uri, cover_image: cover)
    if put_record(DOCUMENT_COLLECTION, rkey, record)
      store_fingerprint(DOCUMENT_COLLECTION, rkey, fingerprint)
    end
  end

  # The Redis key under which a record's content fingerprint is cached. Scoped by
  # collection so a document and the publication can never collide on rkey.
  # @param collection [String]
  # @param rkey [String]
  # @return [String]
  def fingerprint_key(collection, rkey)
    "standard_site:fingerprint:#{collection}:#{rkey}"
  end

  # @param collection [String]
  # @param rkey [String]
  # @return [String, nil] The last-synced fingerprint, or nil if none/no Redis.
  def stored_fingerprint(collection, rkey)
    return unless defined?($redis) && $redis
    $redis.get(fingerprint_key(collection, rkey))
  end

  # Persists a record's content fingerprint (no TTL — it should outlive a build).
  # @param collection [String]
  # @param rkey [String]
  # @param value [String]
  def store_fingerprint(collection, rkey, value)
    return unless defined?($redis) && $redis
    $redis.set(fingerprint_key(collection, rkey), value)
  end

  # Drops a document record's cached fingerprint, so a pruned record doesn't
  # leave a stale entry behind (and would re-sync if it ever reappears).
  # @param rkey [String]
  def forget_fingerprint(rkey)
    return unless defined?($redis) && $redis
    $redis.del(fingerprint_key(DOCUMENT_COLLECTION, rkey))
  end

  # The publication's base URL: the production site root, without a trailing slash.
  # @return [String]
  def publication_url
    ENV['URL'].to_s.chomp('/')
  end

  # Converts an article path into a document path that resolves to the exact
  # canonical page URL (e.g. "/2026/02/24/slug/index.html" -> "/2026/02/24/slug/"),
  # so document verification fetches the page that actually carries the <link> tag.
  # @param path [String]
  # @return [String, nil]
  def document_path(path)
    return if path.blank?
    cleaned = path.to_s.sub(/index\.html\z/, '')
    cleaned.start_with?('/') ? cleaned : "/#{cleaned}"
  end

  # Authenticates with the PDS via an app password and resolves the DID and the
  # repo's PDS service endpoint.
  # @return [Boolean] true if a usable session was established.
  def create_session
    response = HTTParty.post(
      "#{@pds_url}/xrpc/com.atproto.server.createSession",
      body: { identifier: @handle, password: @app_password }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    unless response.success?
      puts "❎ Failed to authenticate with the PDS (HTTP #{response.code})."
      return false
    end
    data = JSON.parse(response.body)
    @access_jwt = data['accessJwt']
    @did = data['did']
    @service_url = pds_endpoint_from_did_doc(data['didDoc']) || @pds_url
    @access_jwt.present? && @did.present?
  rescue StandardError => e
    puts "Error creating PDS session: #{e.message}" if ENV['DEBUG']
    false
  end

  # Extracts the #atproto_pds service endpoint from a DID document, if present.
  # @param doc [Hash, nil]
  # @return [String, nil]
  def pds_endpoint_from_did_doc(doc)
    return if doc.blank?
    service = Array(doc['service']).find { |s| s['id'].to_s.end_with?('#atproto_pds') }
    service&.dig('serviceEndpoint')&.chomp('/')
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
    puts "❎ Failed to put #{collection}/#{rkey} (HTTP #{response.code}: #{response.body})" if !response.success? && ENV['DEBUG']
    response.success?
  end

  # Deletes any document records whose rkey is not in the current set.
  # @param current_rkeys [Array<String>]
  def prune_documents(current_rkeys)
    rkeys_to_prune(list_record_rkeys(DOCUMENT_COLLECTION), current_rkeys).each do |rkey|
      delete_record(DOCUMENT_COLLECTION, rkey)
      forget_fingerprint(rkey)
    end
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
      break unless response.success?
      body = JSON.parse(response.body)
      records = Array(body['records'])
      rkeys.concat(records.map { |r| r['uri'].to_s.split('/').last })
      cursor = body['cursor']
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
      headers: { 'Content-Type' => mime, 'Authorization' => "Bearer #{@access_jwt}" }
    )
    return unless response.success?
    JSON.parse(response.body)['blob']
  rescue StandardError
    nil
  end

  # Fetches a resized image as raw bytes, keeping blobs comfortably under 1MB.
  # The source is resolved to its CloudFront-backed asset URL first (see
  # #cdn_source_url) so transforms never hit Contentful's rate-limited image CDN.
  # In production this uses Netlify's Image CDN (the same path blurhash uses
  # during the build); otherwise it falls back to Contentful's Images API.
  # @return [Array(String, String), nil] [bytes, mime_type] or nil.
  def fetch_resized_image(url, content_type, w:, h:)
    source = cdn_source_url(url)
    source = "https:#{source}" if source.to_s.start_with?('//')
    format = content_type == 'image/png' ? 'png' : 'jpg'
    mime = format == 'png' ? 'image/png' : 'image/jpeg'
    cdn_url = if ENV['URL'].present?
      "#{ENV['URL'].chomp('/')}/.netlify/images?url=#{URI.encode_www_form_component(source)}&w=#{w}&h=#{h}&fit=cover&fm=#{format}"
    else
      images_api_url(source, w: w, h: h, fm: format)
    end
    response = HTTParty.get(cdn_url)
    return unless response.success?
    [response.body, mime]
  rescue StandardError
    nil
  end

  # Resolves an inline image URL to its asset's canonical URL, which has already
  # been rewritten to CloudFront (with a version cache-buster) by Contentful's
  # process_assets. Mirrors ImageHelpers#cdn_image_url so the blob source is
  # cached by CloudFront rather than fetched from Contentful on every transform.
  # Falls back to the original URL if the asset isn't in the index.
  # @param original_url [String]
  # @return [String]
  def cdn_source_url(original_url)
    asset_id = original_url.to_s.split('/')[4]
    asset_index[asset_id].presence || original_url
  end

  # A hash mapping asset sys.id to its (CloudFront-rewritten) URL, from
  # data/assets.json. Empty if the file is missing.
  # @return [Hash<String, String>]
  def asset_index
    @asset_index ||= Array(load_json('data/assets.json')).each_with_object({}) do |asset, index|
      id = asset.dig('sys', 'id')
      index[id] = asset['url'] if id.present?
    end
  end

  # Builds a Contentful Images API URL, normalizing to the images.ctfassets.net
  # host (the downloads host doesn't support image transformations). Used only as
  # the local fallback; CloudFront hosts are left untouched.
  # @return [String]
  def images_api_url(url, w:, h:, fm:)
    uri = URI.parse(url)
    uri.host = 'images.ctfassets.net' if uri.host.to_s.end_with?('ctfassets.net')
    existing = URI.decode_www_form(uri.query || '').to_h
    uri.query = URI.encode_www_form(existing.merge('w' => w, 'h' => h, 'fit' => 'fill', 'fm' => fm))
    uri.to_s
  end

  # @return [Hash] JSON request headers with the bearer token.
  def auth_headers
    { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{@access_jwt}" }
  end

  # Loads and parses a JSON data file, returning nil if missing or invalid.
  # @param path [String]
  # @return [Object, nil]
  def load_json(path)
    return unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue StandardError
    nil
  end

  # Renders Markdown to plain text (no markup, decoded entities, collapsed
  # whitespace), mirroring TextHelpers#sanitize for use outside the template
  # context. Returns nil if blank.
  # @param text [String, nil]
  # @return [String, nil]
  def plain_text(text)
    return if text.blank?
    html = markdown.render(text.to_s)
    decoded = HTMLEntities.new.decode(Sanitize.fragment(html))
    decoded.gsub(/\s+/, ' ').strip.presence
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
