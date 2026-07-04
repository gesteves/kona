# Fetches San Francisco Bay conditions (water temperature, tidal current) from the
# Goodspeed API (NOAA SFBOFS model at station SFB1204). No auth. The response is cached
# in Redis for 5 minutes. `data` returns it wrapped for dot-access (timeseries), or nil.
class Goodspeed < ApplicationService
  GOODSPEED_API_URL = "https://goodspeed-api.fly.dev/latest.json"

  # @return [OpenStruct, nil]
  def data
    fetch_wrapped { fetch }
  end

  private

  def fetch
    rescue_with(context: "Error fetching Goodspeed bay conditions") do
      cached_json("goodspeed:latest", expires_in: 5.minutes) do
        parsed = get_json(GOODSPEED_API_URL)
        parsed if parsed && parsed[:timeseries].present?
      end
    end
  end
end
