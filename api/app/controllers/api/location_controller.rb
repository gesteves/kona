module Api
  # Returns the current location, geocoded into { geocoded, time_zone, elevation } — the
  # source of truth the static site's build fetches (instead of geocoding itself). Not
  # cached, so a build triggered by a location change always gets the fresh value.
  class LocationController < ActionController::Base
    def show
      response.headers["Cache-Control"] = "no-store"

      location = Location.new
      if location.latitude.blank?
        render json: { geocoded: nil, time_zone: nil, elevation: nil }
      else
        render json: GoogleMaps.new(location.latitude, location.longitude).location
      end
    end
  end
end
