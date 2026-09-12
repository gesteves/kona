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

  # How long a session stays in Redis. ⚠️ An access token of Bluesky lives approximately 2 hours,
  # thus this is well below it.
  SESSION_TTL = 55.minutes

  # The prefix of each session key. ⚠️ `spec/support/at_proto_session.rb` removes these keys before
  # each example, thus a session cannot go from one example to the next one.
  SESSION_KEY_PREFIX = "atproto:session:".freeze

  # The PDS refused the token. The caller opens a new session and does the request one time more.
  class UnauthorizedError < StandardError; end

  # The seconds that a record write or a record read can take.
  #
  # ⚠️ **Each call of this file needs a timeout.** `Bluesky#card_image` and `#build_card` also run
  # in the request of `/social/preview`, which has a 20-second rack-timeout, and
  # `Rack::Timeout::RequestTimeoutException` is not a `StandardError`. Thus a host that hangs gives
  # a 500 in place of a card with no picture, and no rescue here can catch it.
  REQUEST_TIMEOUT = 15

  # The seconds that one blob upload can take. It is longer, because a blob is as much as 1MB.
  UPLOAD_TIMEOUT = 30

  # The most bytes of a source image that this file downloads. ⚠️ The worker is a 512MB VM at
  # concurrency 5, thus a request with no cap can end the process.
  MAX_SOURCE_IMAGE_BYTES = 10 * 1024 * 1024

  # The steps of the shrink, in order. ⚠️ One shrink is not always enough: a picture at 1200px and
  # Q80 can stay above a limit, and the record then lost its picture. This walks down the steps and
  # takes the first result that fits. It makes the quality lower first, because a person sees a
  # smaller picture before they see a lower quality.
  SHRINK_STEPS = [
    { width: 1200, quality: 80 },
    { width: 1200, quality: 65 },
    { width: 1200, quality: 50 },
    { width: 900, quality: 50 },
    { width: 700, quality: 45 }
  ].freeze

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

    # Reads the time of a TID that `new_tid` made.
    # @param tid [String] A 13-character TID.
    # @return [Time, nil] The time, or nil for a value with another shape.
    def tid_time(tid)
      # ⚠️ 13 characters of base32 hold 65 bits and a TID holds 64 with its high bit zero, thus the
      # value is below 2**63 and the first character is one of the first EIGHT of the alphabet.
      # Without that check, a content-addressed key from `StandardSite.tid` gives a Time that means
      # nothing in place of nil, and `Bluesky#post!` would write it into createdAt.
      return unless tid.to_s.match?(/\A[#{TID_ALPHABET[0, 8]}][#{TID_ALPHABET}]{12}\z/)

      value = tid.each_char.reduce(0) { |acc, char| (acc * 32) + TID_ALPHABET.index(char) }
      Time.at(Rational(value >> 10, 1_000_000)).utc
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
    @session_handle = handle
    @session_password = app_password

    # ⚠️ `com.atproto.server.createSession` permits 30 calls each 5 minutes and 300 each day, FOR
    # EACH ACCOUNT. One job posts one post of a thread, thus a thread of 25 posts made 25 sessions
    # before its first retry, and a bulk publish adds more. A 429 there reads as "Could not open a
    # Bluesky session" and then tries again for 24 hours.
    return true if load_cached_session

    open_new_session
  end

  # Removes the session that the cache holds and opens a new one.
  #
  # ⚠️ This is what makes the cache safe. A token can stop working before its key expires: a person
  # can revoke it, or change the app password. Without this, each request for the rest of the TTL
  # fails against the same dead token.
  # @return [Boolean] True when a session is available.
  def renew_session!
    $redis.del(session_cache_key)
    open_new_session
  end

  # Runs a request that needs the token, and runs it one time more with a new session when the PDS
  # refuses that token.
  # @yield The request.
  # @return [Object, nil] What the block gives, or nil when the second attempt is also refused.
  def with_valid_session
    yield
  rescue UnauthorizedError
    return unless renew_session!

    begin
      yield
    rescue UnauthorizedError
      Rails.logger.warn("#{at_proto_label}: the PDS refused a token from a new session")
      report_upstream_error("HTTP 401", context: "#{at_proto_label} session", status: 401)
      nil
    end
  end

  # @return [String] The Redis key of this account's session.
  def session_cache_key
    "#{SESSION_KEY_PREFIX}#{@session_handle}"
  end

  # Reads a session that an earlier job opened.
  # @return [Boolean] True when the cache held one.
  def load_cached_session
    raw = $redis.get(session_cache_key)
    return false if raw.blank?

    data = JSON.parse(raw)
    @access_jwt = data["accessJwt"]
    @did = data["did"]
    @service_url = data["serviceUrl"]
    @access_jwt.present? && @did.present?
  rescue StandardError
    false
  end

  # Opens a new session with the PDS and finds the service endpoint of the repo. It is the half of
  # `#open_session` that makes a request, thus a caller that has an empty cache comes here.
  #
  # ⚠️ **Do not give this method a name that an includer also uses.** `StandardSite` has its own
  # `create_session`, which calls `open_session`. With this method named `create_session`, Ruby sent
  # the call above to that copy, which called `open_session` again: the pair made a loop with no end
  # and each cold cache gave a `SystemStackError`. The specs of `StandardSite` each replace
  # `create_session`, thus no example found it.
  # @return [Boolean] True when a session is available.
  def open_new_session
    handle = @session_handle
    app_password = @session_password

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
    return false if @access_jwt.blank? || @did.blank?

    $redis.setex(session_cache_key, SESSION_TTL.to_i,
                 { "accessJwt" => @access_jwt, "did" => @did, "serviceUrl" => @service_url }.to_json)
    true
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
    with_valid_session { put_record_once(collection, rkey, record, validate: validate) }
  end

  # One attempt of `#put_record`. ⚠️ It raises UnauthorizedError for a 401, thus
  # `#with_valid_session` opens a new session and does it one time more.
  # @return [Hash, nil]
  def put_record_once(collection, rkey, record, validate: false)
    body = { repo: @did, collection: collection, rkey: rkey, record: record }
    body[:validate] = validate unless validate.nil?

    response = HTTParty.post("#{@service_url}/xrpc/com.atproto.repo.putRecord",
                             body: body.to_json, headers: auth_headers, timeout: REQUEST_TIMEOUT)
    raise UnauthorizedError if response.code == 401

    unless response.success?
      Rails.logger.warn("#{at_proto_label}: failed to put #{collection}/#{rkey} (HTTP #{response.code}: #{response.body})")
      report_upstream_error("HTTP #{response.code}", context: "#{at_proto_label} putRecord #{collection}/#{rkey}", status: response.code)
      return
    end

    # The keys are strings, thus the reference survives a round trip through the arguments of a
    # Sidekiq job with no change.
    written = JSON.parse(response.body.to_s) rescue {}
    # ⚠️ A reply names this record by its uri AND its cid. A reference with no cid is not valid,
    # and the PDS would refuse the next post of the thread with a message that names that post.
    if written["cid"].blank?
      Rails.logger.warn("#{at_proto_label}: putRecord #{collection}/#{rkey} gave no cid")
      report_upstream_error("putRecord gave no cid", context: "#{at_proto_label} putRecord #{collection}/#{rkey}")
      return
    end

    { "uri" => written["uri"].presence || "at://#{@did}/#{collection}/#{rkey}", "cid" => written["cid"] }
  end

  # Removes a record. A record that is absent is not an error, thus you can do this more than one
  # time.
  #
  # ⚠️ It lives here and not in `StandardSite`, where it was, for the three things that a copy there
  # did not have: a timeout, the retry after a refused token, and a rescue. Each write of this file
  # needs all three.
  # @param collection [String] The lexicon id.
  # @param rkey [String] The record key.
  # @return [Boolean] Whether it succeeded.
  def delete_record(collection, rkey)
    with_valid_session { delete_record_once(collection, rkey) } || false
  rescue StandardError => e
    # ⚠️ A rescue, and not a raise. The prune of a backfill calls this for each record that is no
    # longer current, and one host that cannot be reached must not stop a full reconciliation.
    Rails.logger.warn("#{at_proto_label}: error deleting #{collection}/#{rkey}: #{e.message}")
    report_upstream_error(e, context: "#{at_proto_label} deleteRecord #{collection}/#{rkey}")
    false
  end

  # One attempt of `#delete_record`. ⚠️ It raises UnauthorizedError for a 401, as
  # `#put_record_once` does.
  # @return [Boolean, nil]
  def delete_record_once(collection, rkey)
    response = HTTParty.post(
      "#{@service_url}/xrpc/com.atproto.repo.deleteRecord",
      body: { repo: @did, collection: collection, rkey: rkey }.to_json,
      headers: auth_headers,
      timeout: REQUEST_TIMEOUT
    )
    raise UnauthorizedError if response.code == 401

    unless response.success?
      Rails.logger.warn("#{at_proto_label}: failed to delete #{collection}/#{rkey} (HTTP #{response.code}: #{response.body})")
      report_upstream_error("HTTP #{response.code}", context: "#{at_proto_label} deleteRecord #{collection}/#{rkey}", status: response.code)
      return false
    end

    true
  end

  # The most pages of records to read. A PDS that gives the same cursor for all time, or a cursor
  # that never ends, must not make this loop for all time inside a backfill.
  MAX_LIST_PAGES = 200

  # Each record key of a collection of this repo.
  # @param collection [String] The collection to list.
  # @return [Array<String>] The rkeys. One page comes at a time, through the cursor.
  def list_record_rkeys(collection)
    rkeys = []
    cursor = nil

    MAX_LIST_PAGES.times do
      body = list_records_page(collection, cursor)
      break if body.nil?

      records = Array(body["records"])
      # ⚠️ `compact_blank`: a row with no uri gives "", and the prune would then ask the PDS to
      # delete a record key with no characters.
      rkeys.concat(records.map { |record| record["uri"].to_s.split("/").last }.compact_blank)
      next_cursor = body["cursor"]
      break if next_cursor.blank? || records.empty? || next_cursor == cursor

      cursor = next_cursor
    end

    rkeys
  end

  # One page of `#list_record_rkeys`.
  # @return [Hash, nil] The body, or nil when the page could not be read.
  def list_records_page(collection, cursor)
    with_valid_session do
      query = { repo: @did, collection: collection, limit: 100 }
      query[:cursor] = cursor if cursor.present?

      response = HTTParty.get("#{@service_url}/xrpc/com.atproto.repo.listRecords",
                              query: query, headers: auth_headers, timeout: REQUEST_TIMEOUT)
      raise UnauthorizedError if response.code == 401

      unless response.success?
        report_upstream_error("HTTP #{response.code}", context: "#{at_proto_label} listRecords #{collection}", status: response.code)
        next nil
      end

      JSON.parse(response.body)
    end
  rescue StandardError => e
    report_upstream_error(e, context: "#{at_proto_label} listRecords #{collection}")
    nil
  end

  # Reads one record of this repo.
  # @return [Hash, nil] The `value` of the record, or nil when it is absent or cannot be read.
  def get_own_record(collection, rkey)
    response = HTTParty.get("#{@service_url}/xrpc/com.atproto.repo.getRecord",
                            query: { repo: @did, collection: collection, rkey: rkey },
                            headers: auth_headers, timeout: REQUEST_TIMEOUT)
    return unless response.success?

    JSON.parse(response.body)["value"]
  rescue StandardError
    nil
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
                      query: { repo: did, collection: collection, rkey: rkey },
                      timeout: REQUEST_TIMEOUT)
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

    doc = get_json("https://plc.directory/#{did}", symbolize: false, timeout: REQUEST_TIMEOUT)
    pds_endpoint_from_did_doc(doc)
  end

  # Uploads raw bytes to the PDS as a blob.
  # @param bytes [String] The binary data.
  # @param mime [String] Its content type.
  # @return [Hash, nil] The blob, or nil after a failure. The caller then omits the field.
  def upload_blob(bytes, mime)
    return if @access_jwt.blank? || bytes.blank?

    with_valid_session { upload_blob_once(bytes, mime) }
  end

  # One attempt of `#upload_blob`. ⚠️ It raises UnauthorizedError for a 401, as
  # `#put_record_once` does.
  # @return [Hash, nil]
  def upload_blob_once(bytes, mime)
    response = HTTParty.post(
      "#{@service_url}/xrpc/com.atproto.repo.uploadBlob",
      body: bytes,
      headers: { "Content-Type" => mime, "Authorization" => "Bearer #{@access_jwt}" },
      timeout: UPLOAD_TIMEOUT
    )
    raise UnauthorizedError if response.code == 401

    unless response.success?
      report_upstream_error("HTTP #{response.code}", context: "#{at_proto_label} uploadBlob", status: response.code)
      return
    end
    JSON.parse(response.body)["blob"]
  rescue UnauthorizedError
    raise
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
  # @param limit [Integer] The most bytes that the blob can hold.
  # @return [Hash, nil] The blob, or nil after a failure.
  def upload_image_blob(url, content_type, w:, h:, limit:)
    return if @access_jwt.blank? || url.blank?
    bytes, mime = fetch_resized_image(url, content_type, w: w, h: h)
    return if bytes.blank?

    # ⚠️ The transformation of the source asks for a size and never promises one in bytes. A
    # picture with much detail comes back above the limit, the PDS refuses the record, and the job
    # then tries again for 24 hours for a reason that cannot change. Thus the shrink is here.
    bytes, mime = shrink_image(bytes, limit: limit) if bytes.bytesize > limit
    return if bytes.blank? || bytes.bytesize > limit

    upload_blob(bytes, mime)
  end

  # Makes a picture smaller until it is below a limit.
  # @param bytes [String] The picture.
  # @param limit [Integer] The most bytes that the result can hold.
  # @return [Array(String, String)] [bytes, mime], or [nil, nil] after a failure. ⚠️ The bytes can
  #   still be above the limit when each step was too large; the caller drops the picture.
  def shrink_image(bytes, limit:)
    # ⚠️ The require is **here** and not at the top of the file. libvips is a native library, thus a
    # require at the top makes each path of this file need it, and a record with a small picture
    # would fail where nothing has to shrink anything.
    # ⚠️ LoadError is not a StandardError, thus the rescue below must name it.
    require "vips"

    # ⚠️ `thumbnail_buffer` shrinks at the decode. `new_from_buffer` + `resize` decodes the full
    # picture first, and an 8000×6000 source is then ~144MB of pixels on a 512MB machine.
    smallest = nil
    SHRINK_STEPS.each do |step|
      image = Vips::Image.thumbnail_buffer(bytes, step[:width], size: :down)
      smallest = image.jpegsave_buffer(Q: step[:quality], strip: true)
      return [ smallest, "image/jpeg" ] if smallest.bytesize <= limit
    end

    [ smallest, "image/jpeg" ]
  rescue StandardError, LoadError => e
    report_upstream_error(e, context: "#{at_proto_label} image resize")
    [ nil, nil ]
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

    # ⚠️ `download` stops at MAX_SOURCE_IMAGE_BYTES. A plain `get` reads the full body into memory,
    # and the size of that body belongs to another host.
    picture = download(image_url, max_bytes: MAX_SOURCE_IMAGE_BYTES, timeout: REQUEST_TIMEOUT)
    if picture.blank?
      report_upstream_error("no picture", context: "#{at_proto_label} image fetch", url: image_url)
      return
    end

    [ picture[:body], picture[:content_type].presence || mime ]
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
