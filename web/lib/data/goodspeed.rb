require 'httparty'
require 'json'

# Fetches San Francisco Bay conditions (water temperature, tidal current) from
# the Goodspeed API, which wraps NOAA's SFBOFS model at station SFB1204.
# @see https://goodspeed-api.fly.dev/latest.json
class Goodspeed
  GOODSPEED_API_URL = 'https://goodspeed-api.fly.dev/latest.json'

  # Fetches the latest bay conditions and saves them to data/goodspeed.json.
  # Silently bails out (without writing the file) on any network, HTTP, or
  # parse failure, so downstream helpers can treat a missing file as
  # "no bay data available" rather than crashing the build.
  def save_data
    response = HTTParty.get(GOODSPEED_API_URL)
    return unless response.success?

    parsed = JSON.parse(response.body)
    return if parsed['timeseries'].blank?

    File.open('data/goodspeed.json', 'w') do |f|
      f << response.body
    end
  rescue StandardError
    nil
  end
end
