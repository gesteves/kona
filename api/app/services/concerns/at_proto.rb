# The AT Protocol plumbing that each PDS client here shares: the session, the record writes, and
# the image blobs.
#
# ⚠️ `StandardSite` and `Bluesky` both talk to the **same** PDS with the **same** credentials, from
# `BlueskyCredentials`. Thus the session belongs in one place. Two copies would need two edits when
# the account, the endpoint, or the authentication changes, and a copy that a person forgets fails
# only at the next publish.
#
# An includer must define `at_proto_label`, which names it in each log line and each error report.
# It must also inherit `ApplicationService`, for `report_upstream_error`.
module AtProto
  extend ActiveSupport::Concern

  # The PDS of the account, when `BLUESKY_PDS_URL` has no value.
  DEFAULT_PDS_URL = "https://bsky.social".freeze

  # ⚠️ `new_tid` must give a value that rises at each call, and Puma runs more than one thread.
  TID_LOCK = Mutex.new

  # The "sortable base32" alphabet of a record key.
  # @see https://atproto.com/specs/tid
  TID_ALPHABET = "234567abcdefghijklmnopqrstuvwxyz".freeze

  # The seconds that the session call can take. ⚠️ `StandardSite#connect!` opens a session inside
  # the Bluesky form request, which has a 20-second rack-timeout. A PDS that hangs must give the
  # message of the form and not a 500.
  SESSION_TIMEOUT = 10

  # The seconds that one handle resolution can take. ⚠️ It is shorter than SESSION_TIMEOUT, because
  # the Social media action resolves more than one handle inside one 20-second rack-timeout request.
  # Refer to Admin::SocialController#bluesky_handle_error.
  RESOLVE_TIMEOUT = 5

  class_methods do
    # Encodes a 64-bit value as a 13-character TID.
    # @param value [Integer]
    # @return [String]
    def encode_tid(value)
      encoded = +""
      while value.positive?
        encoded = TID_ALPHABET[value % 32] + encoded
        value /= 32
      end
      encoded.rjust(13, TID_ALPHABET[0])
    end

    # Makes a record key for a new record, from the current time.
    #
    # ⚠️ The caller makes this **before** it adds a job, and the job then uses `putRecord`. Thus a
    # second attempt writes the same record again at the same key, and it does not add a second
    # post. `createRecord` makes its own key, thus each retry there is a new post.
    #
    # The shape is the shape of a TID: a zero bit, 53 bits of microseconds, and 10 bits of a random
    # clock id. Thus a later record sorts after an earlier one, which is what a feed needs.
    # @return [String] A 13-character TID.
    def new_tid
      # ⚠️ It is MONOTONIC, and the clock alone is not. The caller makes one key for each post of a
      # thread in one loop, thus two calls land in the same microsecond. The 10 low bits are
      # random, thus the keys of a thread would then sort in a random order and a reply could come
      # above its own root. This gives the next microsecond in place of a repeat.
      TID_LOCK.synchronize do
        micros = (Time.now.to_r * 1_000_000).to_i & ((1 << 53) - 1)
        @last_tid_micros = @last_tid_micros.to_i >= micros ? @last_tid_micros + 1 : micros
        encode_tid((@last_tid_micros << 10) | SecureRandom.random_number(1 << 10))
      end
    end
  end

  private

  # @return [String] The base URL of the PDS, with no trailing slash.
  def pds_url
    @pds_url ||= (ENV["BLUESKY_PDS_URL"].presence || DEFAULT_PDS_URL).chomp("/")
  end

  # Opens a session with the PDS and finds the service endpoint of the repo.
  #
  # It sets `@access_jwt`, `@did`, and `@service_url`. The caller checks the return value before it
  # writes anything.
  # @param handle [String]
  # @param app_password [String]
  # @return [Boolean] True when a session is available.
  def open_session(handle:, app_password:)
    response = HTTParty.post(
      "#{pds_url}/xrpc/com.atproto.server.createSession",
      body: { identifier: handle, password: app_password }.to_json,
      headers: { "Content-Type" => "application/json" },
      timeout: SESSION_TIMEOUT
    )
    unless response.success?
      Rails.logger.warn("#{at_proto_label}: failed to authenticate with the PDS (HTTP #{response.code})")
      report_upstream_error("HTTP #{response.code}", context: "#{at_proto_label} PDS session", status: response.code)
      return false
    end

    data = JSON.parse(response.body)
    @access_jwt = data["accessJwt"]
    @did = data["did"]
    # The DID document names the true host of the repo, which is not always the host that answered
    # the session. Each write goes to that host.
    @service_url = pds_endpoint_from_did_doc(data["didDoc"]) || pds_url
    @access_jwt.present? && @did.present?
  rescue StandardError => e
    Rails.logger.error("#{at_proto_label}: error creating PDS session: #{e.message}")
    report_upstream_error(e, context: "#{at_proto_label} PDS session")
    false
  end

  # @param doc [Hash, nil] A DID document.
  # @return [String, nil] The #atproto_pds service endpoint of the document.
  def pds_endpoint_from_did_doc(doc)
    return if doc.blank?
    service = Array(doc["service"]).find { |s| s["id"].to_s.end_with?("#atproto_pds") }
    service&.dig("serviceEndpoint")&.chomp("/")
  end

  # @return [Hash] JSON request headers with the bearer token.
  def auth_headers
    { "Content-Type" => "application/json", "Authorization" => "Bearer #{@access_jwt}" }
  end

  # Makes or replaces a record. The repo, the collection, and the rkey identify it, thus you can do
  # this more than one time and get one record.
  # @param collection [String] The lexicon id.
  # @param rkey [String] The record key.
  # @param record [Hash] The record.
  # ⚠️ It answers with the **reference** of the record and not with a Boolean, because a reply
  # names its parent by `uri` **and** `cid`, and an `at://` URI holds no CID. Each caller that only
  # asks "did it work" still reads it correctly: a Hash is truthy and nil is not.
  # @param validate [Boolean, nil] False where the PDS does not know the lexicon. Nil omits it.
  # @return [Hash, nil] `{ "uri" =>, "cid" => }`, or nil after a failure.
  def put_record(collection, rkey, record, validate: false)
    body = { repo: @did, collection: collection, rkey: rkey, record: record }
    body[:validate] = validate unless validate.nil?

    response = HTTParty.post("#{@service_url}/xrpc/com.atproto.repo.putRecord",
                             body: body.to_json, headers: auth_headers)
    unless response.success?
      Rails.logger.warn("#{at_proto_label}: failed to put #{collection}/#{rkey} (HTTP #{response.code}: #{response.body})")
      report_upstream_error("HTTP #{response.code}", context: "#{at_proto_label} putRecord #{collection}/#{rkey}", status: response.code)
      return
    end

    # The keys are strings, thus the reference survives a round trip through the arguments of a
    # Sidekiq job with no change.
    written = JSON.parse(response.body.to_s) rescue {}
    { "uri" => written["uri"].presence || "at://#{@did}/#{collection}/#{rkey}", "cid" => written["cid"] }
  end

  # Splits an `at://` URI into its three parts.
  # @param uri [String, nil]
  # @return [Array(String, String, String), nil] [did, collection, rkey], or nil for a URI with
  #   another shape.
  def parse_at_uri(uri)
    match = uri.to_s.match(%r{\Aat://(?<did>[^/]+)/(?<collection>[^/]+)/(?<rkey>[^/?\#]+)\z})
    return if match.nil?

    [ match[:did], match[:collection], match[:rkey] ]
  end

  # Reads one record and makes a `com.atproto.repo.strongRef` of it.
  #
  # ⚠️ A strongRef needs the **CID**, and an `at://` URI does not hold one. Thus the only way to
  # make one is to read the record. The CID also changes at each write, thus this cannot be cached
  # for a long time: a ref with an old CID names a version that is gone.
  # @param uri [String] An at:// URI.
  # @return [Hash, nil] `{ "uri" =>, "cid" => }`, or nil when the record cannot be read.
  def strong_ref(uri)
    did, collection, rkey = parse_at_uri(uri)
    return if did.blank?

    service = service_for(did)
    return if service.blank?

    record = get_json("#{service}/xrpc/com.atproto.repo.getRecord",
                      query: { repo: did, collection: collection, rkey: rkey })
    return if record.blank? || record[:cid].blank?

    { "uri" => record[:uri].presence || uri, "cid" => record[:cid] }
  rescue StandardError => e
    report_upstream_error(e, context: "#{at_proto_label} getRecord")
    nil
  end

  # The host that holds a repo.
  #
  # ⚠️ A PDS answers `getRecord` for its **own** repos only. Thus a DID that is not ours needs its
  # DID document first. `did:plc` resolves at the directory, and each other method gives nil, thus
  # the caller then makes no ref and the card is an ordinary one.
  # @param did [String]
  # @return [String, nil]
  def service_for(did)
    return @service_url if did == @did && @service_url.present?
    return unless did.start_with?("did:plc:")

    doc = get_json("https://plc.directory/#{did}", symbolize: false)
    pds_endpoint_from_did_doc(doc)
  end

  # Uploads raw bytes to the PDS as a blob.
  # @param bytes [String] The binary data.
  # @param mime [String] Its content type.
  # @return [Hash, nil] The blob, or nil after a failure. The caller then omits the field.
  def upload_blob(bytes, mime)
    return if @access_jwt.blank? || bytes.blank?

    response = HTTParty.post(
      "#{@service_url}/xrpc/com.atproto.repo.uploadBlob",
      body: bytes,
      headers: { "Content-Type" => mime, "Authorization" => "Bearer #{@access_jwt}" }
    )
    unless response.success?
      report_upstream_error("HTTP #{response.code}", context: "#{at_proto_label} uploadBlob", status: response.code)
      return
    end
    JSON.parse(response.body)["blob"]
  rescue StandardError => e
    report_upstream_error(e, context: "#{at_proto_label} uploadBlob")
    nil
  end

  # Downloads a smaller copy of a **Contentful** image and uploads it as a blob.
  #
  # ⚠️ `StandardSite` uses this, and `Bluesky` does not: a social card takes its picture from the
  # og:image of any URL, which is not always a Contentful asset.
  # @param url [String] The source image.
  # @param content_type [String, nil] The content type of the source.
  # @param w [Integer] The width to ask for.
  # @param h [Integer] The height to ask for.
  # @return [Hash, nil] The blob, or nil after a failure.
  def upload_image_blob(url, content_type, w:, h:)
    return if @access_jwt.blank? || url.blank?
    bytes, mime = fetch_resized_image(url, content_type, w: w, h: h)
    return if bytes.blank?

    upload_blob(bytes, mime)
  end

  # Gets a smaller image as raw bytes from the Contentful Images API. This keeps each blob below
  # 1MB. A direct request to Contentful is satisfactory here, because this runs only when a person
  # publishes or shares a post.
  # @return [Array(String, String), nil] [bytes, mime_type], or nil after a failure.
  def fetch_resized_image(url, content_type, w:, h:)
    return if url.blank?
    source = url.to_s.start_with?("//") ? "https:#{url}" : url
    format = content_type == "image/png" ? "png" : "jpg"
    mime = format == "png" ? "image/png" : "image/jpeg"
    image_url = images_api_url(source, w: w, h: h, fm: format)

    response = HTTParty.get(image_url)
    unless response.success?
      report_upstream_error("HTTP #{response.code}", context: "#{at_proto_label} image fetch", status: response.code, url: image_url)
      return
    end
    [ response.body, mime ]
  rescue StandardError => e
    report_upstream_error(e, context: "#{at_proto_label} image fetch")
    nil
  end

  # Cuts a string to a number of grapheme clusters. Each text field of a record has a limit in
  # graphemes, and `String#length` counts UTF-16 code units.
  # @param str [String, nil]
  # @param max [Integer]
  # @return [String, nil] The string, made shorter.
  def truncate_graphemes(str, max)
    return str if str.blank?
    graphemes = str.scan(/\X/)
    graphemes.length > max ? graphemes.first(max).join : str
  end

  # Makes a Contentful Images API URL. It always uses images.ctfassets.net, because the downloads
  # host does no transformation.
  # @return [String]
  def images_api_url(url, w:, h:, fm:)
    uri = URI.parse(url)
    uri.host = "images.ctfassets.net" if uri.host.to_s.end_with?("ctfassets.net")
    existing = URI.decode_www_form(uri.query || "").to_h
    uri.query = URI.encode_www_form(existing.merge("w" => w, "h" => h, "fit" => "fill", "fm" => fm))
    uri.to_s
  end
end
