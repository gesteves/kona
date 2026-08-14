# Fetches San Francisco Bay conditions (water temperature, tidal current) from the
# Goodspeed API (NOAA SFBOFS model at station SFB1204). No auth. The response is cached
# in Redis for 5 minutes. `data` returns it wrapped for dot-access (timeseries), or nil.
#
# Opt-in: with `GOODSPEED_API_URL` unset the service is inert and returns nil, which every
# consumer already treats as "no bay data" — the water-temperature sentence and the race-day
# bay readings are simply omitted.
class Goodspeed < ApplicationService
  # @return [OpenStruct, nil]
  def data
    fetch_wrapped { fetch }
  end

  private

  def fetch
    url = ENV["GOODSPEED_API_URL"]
    return if url.blank?

    rescue_with(context: "Error fetching Goodspeed bay conditions") do
      cached_json("goodspeed:latest", expires_in: 5.minutes) do
        parsed = get_json(url)
        parsed if parsed && parsed[:timeseries].present?
      end
    end
  end
end
