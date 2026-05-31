require "httparty"

# Base class for the external-API service objects. Centralizes the read-through Redis cache,
# the HTTParty + JSON-parse boilerplate, the camelCase→snake_case key transform, and the
# retry/error-handling patterns that were copy-pasted across every service.
class ApplicationService
  private

  # Read-through JSON cache. Returns the parsed cached value when the key is populated;
  # otherwise yields, caches the block's (JSON-serializable) result, and returns it. A blank
  # block result is returned without being cached, matching the services' "don't cache empty"
  # behavior.
  #
  # @param key [String] The Redis key.
  # @param expires_in [ActiveSupport::Duration, nil] TTL; nil caches indefinitely.
  # @param symbolize [Boolean] Parse cached JSON with symbolized keys (false for the
  #   string-keyed services, e.g. Intervals and PurpleAir).
  # @yieldreturn [Object] The freshly fetched, JSON-serializable value.
  # @return [Object, nil]
  def cached_json(key, expires_in: nil, symbolize: true)
    cached = $redis.get(key)
    return JSON.parse(cached, symbolize_names: symbolize) if cached.present?

    value = yield
    return value if value.blank?

    if expires_in
      $redis.setex(key, expires_in, value.to_json)
    else
      $redis.set(key, value.to_json)
    end
    value
  end

  # GETs a URL and returns the parsed JSON body, or nil on a non-success response.
  # @param symbolize [Boolean] Parse with symbolized keys.
  # @param options [Hash] Passed through to HTTParty (query, headers, basic_auth, …).
  def get_json(url, symbolize: true, **options)
    parse_json(HTTParty.get(url, **options), symbolize: symbolize)
  end

  # POSTs to a URL and returns the parsed JSON body, or nil on a non-success response.
  # @param symbolize [Boolean] Parse with symbolized keys.
  # @param options [Hash] Passed through to HTTParty (body, headers, query, …).
  def post_json(url, symbolize: true, **options)
    parse_json(HTTParty.post(url, **options), symbolize: symbolize)
  end

  # @param response [HTTParty::Response]
  # @return [Object, nil] The parsed body, or nil when the response was not successful.
  def parse_json(response, symbolize: true)
    return unless response.success?

    JSON.parse(response.body, symbolize_names: symbolize)
  end

  # Recursively rewrites camelCase string/symbol keys to snake_case symbols.
  # @param object [Hash, Array, nil]
  def underscore_keys(object)
    object&.deep_transform_keys { |key| key.to_s.underscore.to_sym }
  end

  # Runs the block, retrying with exponential backoff (2, 4, 8, … seconds) on any error,
  # returning nil once the attempts are exhausted.
  # @param max [Integer] Maximum retries after the first attempt.
  def with_retries(max: 3)
    attempts = 0
    begin
      yield
    rescue StandardError
      attempts += 1
      if attempts <= max
        sleep(2**attempts)
        retry
      end
      nil
    end
  end

  # Runs the block, logging and swallowing any error and returning the fallback instead.
  # @param fallback [Object] The value to return on error (default nil).
  # @param context [String] A label for the log line.
  def rescue_with(fallback = nil, context: self.class.name)
    yield
  rescue StandardError => e
    Rails.logger.error("#{context}: #{e}")
    fallback
  end
end
