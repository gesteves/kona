require "httparty"
require "digest"

# The base class for the external-API service objects. It has the read-through Redis cache, the
# common HTTParty and JSON-parse code, the key transforms, and the shared retry and error code.
class ApplicationService
  include UpstreamIsolation

  # The bang methods raise this when a response is not a success. It holds the status and the
  # body, thus a caller can select an action from the type of failure and does not compare
  # message text.
  class HttpError < StandardError
    attr_reader :status, :body

    def initialize(status, body, url)
      @status = status
      @body = body
      super("HTTP #{status} from #{url}")
    end
  end

  # Marks a key whose upstream gave no data. It is not correct JSON, on purpose, thus it can
  # never look like a stored value. It is above `private` because `private` does not apply to a
  # constant, and the specs read it.
  EMPTY_SENTINEL = "__EMPTY__".freeze

  private

  # A read-through JSON cache. In development it does not use the cache, thus you see a change
  # and do not wait for a TTL.
  #
  # It uses the shared $redis, and not Rails.cache. The keyspace is older than this app and keeps
  # key names that you can find with grep, and the behavior is different from Rails.cache.fetch.
  #
  # ⚠️ The cache holds a blank result only when you give `empty_expires_in`, and a caller of an
  # upstream with a rate limit **must** give it. `parse_json` returns nil for each non-2xx. Thus
  # with no negative TTL, a 429 puts nothing in the cache and each subsequent request asks again
  # with no delay. That is, the one condition that causes a rate-limit failure is also the one
  # that removes all the control. Keep the negative TTL short: it is a delay, not a cache.
  # @param key [String] The Redis key.
  # @param expires_in [ActiveSupport::Duration, Integer, nil] The TTL in seconds. Only a positive
  #   TTL puts a value in the cache. Nothing stays in the cache for all time.
  # @param empty_expires_in [ActiveSupport::Duration, Integer, nil] The TTL for a blank result.
  #   Nil, the default, does not put a blank result in the cache.
  # @param symbolize [Boolean] True to parse with symbol keys.
  # @yieldreturn [Object] The new value, which must be JSON-serializable.
  # @return [Object, nil] Nil for a blank value in the cache, or the value from the block. Thus a
  #   caller that must know nil from [] has to correct the result.
  def cached_json(key, expires_in: nil, empty_expires_in: nil, symbolize: true)
    return yield if Rails.env.development?

    cached = $redis.get(key)
    if cached.present?
      return nil if cached == EMPTY_SENTINEL
      return JSON.parse(cached, symbolize_names: symbolize)
    end

    value = yield
    if value.blank?
      empty_ttl = empty_expires_in.to_i
      $redis.setex(key, empty_ttl, EMPTY_SENTINEL) if empty_ttl.positive?
      return value
    end

    ttl = expires_in.to_i if expires_in
    $redis.setex(key, ttl, value.to_json) if ttl&.positive?
    value
  end

  # A short digest of the things that decide the *shape* of a cached value, which is usually the
  # query that made it. Put it at the end of a cache key.
  #
  # This replaces a `:v2` suffix that a person increases by hand. Such a suffix works only if the
  # person who edits a query also increases it in the same commit. If they do not, the cache
  # gives values with no data for the fields that the new code reads, and the result is a nil
  # dereference at some other place. A digest changes by itself.
  # ⚠️ A NUL joins the inputs, and the code writes it as the `\x00` escape and not as a zero byte.
  # NUL is the separator because no input can contain it, thus ["ab", "c"] and ["a", "bc"] cannot
  # give the same digest. The escape is necessary because git counts a file with a raw zero byte
  # as binary, and that stops each line diff, each blame, and each PR review in the file.
  # @param inputs [Array<#to_s>] The things that must invalidate the cache when they change.
  # @return [String] An 8-character hex digest.
  def cache_version(*inputs)
    Digest::SHA256.hexdigest(inputs.join("\x00"))[0, 8]
  end

  # GETs a URL.
  # @param symbolize [Boolean] True to parse with symbol keys.
  # @param options [Hash] The options that go to HTTParty.
  # @return [Object, nil] The parsed body, or nil if the response is not a success.
  def get_json(url, symbolize: true, **options)
    parse_json(HTTParty.get(url, **options), symbolize: symbolize)
  end

  # POSTs to a URL.
  # @param symbolize [Boolean] True to parse with symbol keys.
  # @param options [Hash] The options that go to HTTParty.
  # @return [Object, nil] The parsed body, or nil if the response is not a success.
  def post_json(url, symbolize: true, **options)
    parse_json(HTTParty.post(url, **options), symbolize: symbolize)
  end

  # The same as get_json, but it raises and does not return nil on a failure. Thus with_retries
  # can do it again.
  # @raise [HttpError] If the response is not a success.
  def get_json!(url, symbolize: true, **options)
    parse_json!(HTTParty.get(url, **options), symbolize: symbolize)
  end

  # The same as post_json, but it raises and does not return nil on a failure.
  # @see #get_json!
  # @raise [HttpError] If the response is not a success.
  def post_json!(url, symbolize: true, **options)
    parse_json!(HTTParty.post(url, **options), symbolize: symbolize)
  end

  # Downloads a URL, and reads at most `max_bytes` of it.
  #
  # ⚠️ The worker is a 512MB VM at concurrency 5, and a body that goes into memory with no limit
  # has killed it before (refer to AssetMirror). This method reads the body in fragments and stops
  # at the limit, thus a page or a picture of any size costs at most `max_bytes` of memory.
  #
  # ⚠️ It follows each redirect itself, and it checks each hop with PublicAddress. Another site
  # names the URL, thus a public page can send this code to a private address.
  # @param url [String]
  # @param max_bytes [Integer] The most bytes to keep.
  # @param keep_head [Boolean] True to return the first `max_bytes` of a body that is longer. False,
  #   the default, returns nil for such a body.
  # @param limit [Integer] The most redirects to follow.
  # @param options [Hash] The options that go to HTTParty.
  # @return [Hash, nil] `{ body:, content_type:, url: }` for a 2xx, where `url` is the final URL
  #   after each redirect. Nil for each other status, for an empty body, for a body past the
  #   limit when `keep_head` is false, and for a URL that is not public.
  def download(url, max_bytes:, keep_head: false, limit: 5, **options)
    unless PublicAddress.public_url?(url)
      Rails.logger.info("#{self.class.name}: refused a download from a URL that is not public")
      return
    end

    body = String.new(encoding: Encoding::BINARY)
    content_type = nil
    received = false
    response = nil

    catch(:capped) do
      response = HTTParty.get(url, **options, follow_redirects: false, stream_body: true) do |fragment|
        next unless (200..299).cover?(fragment.code)

        received = true
        content_type ||= fragment.http_response["content-type"].to_s
        body << fragment.to_s.b
        throw :capped if body.bytesize > max_bytes
      end
    end

    if response && (300..399).cover?(response.code.to_i)
      location = response.headers["location"].to_s
      return if location.blank? || limit <= 0

      next_url = URI.join(url, location).to_s
      return download(next_url, max_bytes: max_bytes, keep_head: keep_head, limit: limit - 1, **options)
    end

    return unless received

    if body.bytesize > max_bytes
      return unless keep_head
      body = body.byteslice(0, max_bytes)
    end

    # The charset of the response names the encoding of the text, as HTTParty does for a body that
    # it reads in one piece. A body with no charset, or with a name that Ruby does not know, stays
    # binary, and Nokogiri then reads the meta tag.
    charset = content_type.to_s[/charset=["']?([^;"'\s]+)/i, 1]
    begin
      body.force_encoding(charset) if charset
    rescue ArgumentError
      nil
    end

    { body: body, content_type: content_type.to_s, url: url.to_s }
  end

  # PUTs to a URL. There is no method that returns nil on a failure, on purpose. A PUT is a
  # write, and a caller needs the failure status to select between another attempt and a smaller
  # result.
  # @param symbolize [Boolean] True to parse with symbol keys.
  # @param options [Hash] The options that go to HTTParty.
  # @raise [HttpError] If the response is not a success.
  def put_json!(url, symbolize: true, **options)
    parse_json!(HTTParty.put(url, **options), symbolize: symbolize)
  end

  # @param response [HTTParty::Response] The response to parse.
  # @return [Object, nil] The parsed body, or nil if the body is empty.
  # @raise [HttpError] If the response is not a success.
  def parse_json!(response, symbolize: true)
    raise HttpError.new(response.code, response.body, response.request&.last_uri) unless response.success?

    JSON.parse(response.body, symbolize_names: symbolize) if response.body.present?
  end

  # @param response [HTTParty::Response] The response to parse.
  # @return [Object, nil] The parsed body, or nil if the response is not a success or is empty.
  def parse_json(response, symbolize: true)
    unless response.success?
      report_upstream_error("HTTP #{response.code}", status: response.code, url: response.request&.last_uri&.to_s)
      return
    end

    # ⚠️ The same check as in parse_json!. The documentation says that this method always gives a
    # result: get_json and post_json return "the parsed body, or nil" and never raise. Thus a 204,
    # or a 200 with an empty body, must not become a JSON::ParserError in a caller that has no
    # rescue.
    JSON.parse(response.body, symbolize_names: symbolize) if response.body.present?
  end

  # Changes each camelCase key into a snake_case symbol, at each level.
  # @param object [Hash, Array, nil] The object to change.
  def underscore_keys(object)
    object&.deep_transform_keys { |key| key.to_s.underscore.to_sym }
  end

  # A dot-access object for the payload of a service. The app keeps the value, and it keeps a nil
  # result too. Thus the instance does not do a failed fetch again.
  # @yieldreturn [Hash, Array, nil] The raw payload.
  # @return [OpenStruct, Array, nil]
  def fetch_wrapped
    return @wrapped_data if defined?(@wrapped_data)
    raw = yield
    @wrapped_data = raw && DeepOstruct.wrap(raw)
  end

  # @return [Boolean] True if the caller gave correct coordinates. The geo services do nothing
  #   without them.
  def coordinates?
    @latitude.present? && @longitude.present?
  end

  # Runs the block. On an error it waits, then does the block again, and each wait is two times
  # the last one.
  #
  # ⚠️ The wait occurs in the calling thread. The defaults (2s, then 4s, then 8s) are for the
  # Sidekiq jobs, and together they are longer than the full 20s rack-timeout budget. Thus a
  # caller in a **request path** must give a `deadline`. If it does not, the waits alone are
  # longer than the request, and the widget gives a 500 instead of an empty fragment.
  #
  # There is no random change to the wait: the retry counts are small and each upstream has one
  # tenant, thus there is no group of clients to separate in time.
  # @param max [Integer] The maximum number of attempts after the first attempt.
  # @param base_delay [Numeric] The seconds to wait before the second attempt. Each wait is two
  #   times the last one.
  # @param deadline [Numeric] The maximum seconds for this call, and this includes the waits. An
  #   attempt does not occur if its wait would end after the deadline.
  # @return [Object, nil] The value from the block, or nil after the attempts or the deadline end.
  def with_retries(max: 3, base_delay: 2, deadline: Float::INFINITY)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    attempts = 0
    begin
      yield
    rescue StandardError => e
      attempts += 1
      delay = base_delay * (2**(attempts - 1))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      if attempts <= max && (elapsed + delay) < deadline
        sleep(delay)
        retry
      end
      report_upstream_error(e)
      nil
    end
  end

  # Runs the block. It writes each error to the log and does not raise. It is a short form of
  # UpstreamIsolation#safely.
  # @param fallback [Object] The value to return on an error.
  # @param context [String] A label for the log line.
  def rescue_with(fallback = nil, context: self.class.name)
    safely(self.class.name, fallback, context: context) { yield }
  end

  # Sends an upstream failure that the code caught to Bugsnag, with the class name of this
  # service as a tag.
  # @see ErrorReporter.report_upstream
  def report_upstream_error(error, context: self.class.name, status: nil, url: nil)
    ErrorReporter.report_upstream(error, service: self.class.name, context: context, status: status, url: url)
  end
end
