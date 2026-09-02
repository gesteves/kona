# Gets the conditions of San Francisco Bay — the water temperature and the tidal current — from the
# Goodspeed API, which uses the NOAA SFBOFS model at station SFB1204. It needs no authentication.
# Redis caches the response for 5 minutes. `data` gives the timeseries in an object with dot access,
# or nil.
#
# This service is optional: with no value in `GOODSPEED_API_URL` it does nothing and returns nil.
# Each caller already reads that as "no bay data", thus the water-temperature sentence and the
# race-day bay readings are absent.
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
      cached_json("goodspeed:latest", expires_in: 5.minutes, empty_expires_in: 1.minute) do
        parsed = get_json(url)
        parsed if parsed && parsed[:timeseries].present?
      end
    end
  end
end
