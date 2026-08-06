require "httparty"

# Base class for the external-API service objects: the read-through Redis cache, the HTTParty
# and JSON-parse boilerplate, key transforms, and the shared retry/error handling.
class ApplicationService
  include UpstreamIsolation

  # Raised by the bang variants on a non-success response. Carries the status and body so
  # callers can branch on the failure mode instead of string-matching messages.
  class HttpError < StandardError
    attr_reader :status, :body

    def initialize(status, body, url)
      @status = status
      @body = body
      super("HTTP #{status} from #{url}")
    end
  end

  private

  # Read-through JSON cache. A blank result is returned but never cached, and development
  # bypasses the cache entirely so changes are visible without waiting out a TTL.
  #
  # Uses the shared $redis rather than Rails.cache: the keyspace predates this app and keeps
  # greppable key names, and the semantics differ from Rails.cache.fetch.
  # @param key [String] The Redis key.
  # @param expires_in [ActiveSupport::Duration, Integer, nil] TTL in seconds. Only a positive
  #   TTL caches — nothing is ever cached indefinitely.
  # @param symbolize [Boolean] Whether to parse with symbolized keys.
  # @yieldreturn [Object] The freshly fetched, JSON-serializable value.
  # @return [Object, nil]
  def cached_json(key, expires_in: nil, symbolize: true)
    return yield if Rails.env.development?

    cached = $redis.get(key)
    return JSON.parse(cached, symbolize_names: symbolize) if cached.present?

    value = yield
    return value if value.blank?

    ttl = expires_in.to_i if expires_in
    $redis.setex(key, ttl, value.to_json) if ttl&.positive?
    value
  end

  # GETs a URL.
  # @param symbolize [Boolean] Whether to parse with symbolized keys.
  # @param options [Hash] Passed through to HTTParty.
  # @return [Object, nil] The parsed body, or nil on a non-success response.
  def get_json(url, symbolize: true, **options)
    parse_json(HTTParty.get(url, **options), symbolize: symbolize)
  end

  # POSTs to a URL.
  # @param symbolize [Boolean] Whether to parse with symbolized keys.
  # @param options [Hash] Passed through to HTTParty.
  # @return [Object, nil] The parsed body, or nil on a non-success response.
  def post_json(url, symbolize: true, **options)
    parse_json(HTTParty.post(url, **options), symbolize: symbolize)
  end

  # Like get_json, but raises rather than swallowing a failure to nil — which is what makes it
  # retryable inside with_retries.
  # @raise [HttpError] on a non-success response.
  def get_json!(url, symbolize: true, **options)
    parse_json!(HTTParty.get(url, **options), symbolize: symbolize)
  end

  # Like post_json, but raises rather than swallowing a failure to nil.
  # @see #get_json!
  # @raise [HttpError] on a non-success response.
  def post_json!(url, symbolize: true, **options)
    parse_json!(HTTParty.post(url, **options), symbolize: symbolize)
  end

  # PUTs to a URL. There is deliberately no swallowing variant: PUTs are writes, and callers
  # need the failure's status to choose between retrying and degrading.
  # @param symbolize [Boolean] Whether to parse with symbolized keys.
  # @param options [Hash] Passed through to HTTParty.
  # @raise [HttpError] on a non-success response.
  def put_json!(url, symbolize: true, **options)
    parse_json!(HTTParty.put(url, **options), symbolize: symbolize)
  end

  # @param response [HTTParty::Response] The response to parse.
  # @return [Object, nil] The parsed body, or nil when it's empty.
  # @raise [HttpError] when the response wasn't successful.
  def parse_json!(response, symbolize: true)
    raise HttpError.new(response.code, response.body, response.request&.last_uri) unless response.success?

    JSON.parse(response.body, symbolize_names: symbolize) if response.body.present?
  end

  # @param response [HTTParty::Response] The response to parse.
  # @return [Object, nil] The parsed body, or nil when the response wasn't successful.
  def parse_json(response, symbolize: true)
    unless response.success?
      report_upstream_error("HTTP #{response.code}", status: response.code, url: response.request&.last_uri&.to_s)
      return
    end

    JSON.parse(response.body, symbolize_names: symbolize)
  end

  # Recursively rewrites camelCase keys to snake_case symbols.
  # @param object [Hash, Array, nil] The object to transform.
  def underscore_keys(object)
    object&.deep_transform_keys { |key| key.to_s.underscore.to_sym }
  end

  # Memoized dot-access wrapper for a service's payload. Memoizes even a nil result, so a
  # failed fetch isn't retried within the instance.
  # @yieldreturn [Hash, Array, nil] The raw payload.
  # @return [OpenStruct, Array, nil]
  def fetch_wrapped
    return @wrapped_data if defined?(@wrapped_data)
    raw = yield
    @wrapped_data = raw && DeepOstruct.wrap(raw)
  end

  # @return [Boolean] Whether usable coordinates were supplied. The geo services no-op
  #   without them.
  def coordinates?
    @latitude.present? && @longitude.present?
  end

  # Runs the block, retrying with exponential backoff on any error.
  # @param max [Integer] Maximum retries after the first attempt.
  # @return [Object, nil] The block's value, or nil once attempts are exhausted.
  def with_retries(max: 3)
    attempts = 0
    begin
      yield
    rescue StandardError => e
      attempts += 1
      if attempts <= max
        sleep(2**attempts)
        retry
      end
      report_upstream_error(e)
      nil
    end
  end

  # Runs the block, logging and swallowing any error. Sugar over UpstreamIsolation#safely.
  # @param fallback [Object] The value to return on error.
  # @param context [String] A label for the log line.
  def rescue_with(fallback = nil, context: self.class.name)
    safely(self.class.name, fallback, context: context) { yield }
  end

  # Reports a handled upstream failure to Bugsnag, tagged with this service's class name.
  # @see ErrorReporter.report_upstream
  def report_upstream_error(error, context: self.class.name, status: nil, url: nil)
    ErrorReporter.report_upstream(error, service: self.class.name, context: context, status: status, url: url)
  end
end
