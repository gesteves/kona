require "httparty"

# Fetches San Francisco Bay conditions (water temperature, tidal current) from the
# Goodspeed API (NOAA SFBOFS model at station SFB1204). No auth. The response is cached
# in Redis for 5 minutes. `data` returns it wrapped for dot-access (timeseries), or nil.
class Goodspeed
  GOODSPEED_API_URL = "https://goodspeed-api.fly.dev/latest.json"

  # @return [OpenStruct, nil]
  def data
    return @data if defined?(@data)
    @data = fetch&.then { |parsed| DeepOstruct.wrap(parsed) }
  end

  private

  def fetch
    cache_key = "goodspeed:latest"
    cached = $redis.get(cache_key)
    return JSON.parse(cached, symbolize_names: true) if cached.present?

    response = HTTParty.get(GOODSPEED_API_URL)
    return unless response.success?

    parsed = JSON.parse(response.body, symbolize_names: true)
    return if parsed[:timeseries].blank?

    $redis.setex(cache_key, 5.minutes, response.body)
    parsed
  rescue StandardError => e
    Rails.logger.error("Error fetching Goodspeed bay conditions: #{e}")
    nil
  end
end
