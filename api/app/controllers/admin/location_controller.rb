module Admin
  # The current location, as a map you drop a pin on. Writes the same Redis key as the
  # bearer-gated POST /api/location — through the same Location.store — so this is a front-end
  # over the write that already existed, not a second way to store a location.
  class LocationController < BaseController
    # The basemap for picking a place.
    #
    # ⚠️ Deliberately not MAPBOX_STYLE_URL. That names the default style for *GPX renders*, where
    # a custom style is the whole point; here it would be a basemap chosen for a race photo, with
    # the streets and labels this page exists to read taken out of it.
    MAP_STYLE = "mapbox://styles/mapbox/streets-v12".freeze

    # Zoom levels: close enough to recognize a neighborhood, or the whole world when there's
    # nothing to center on yet.
    LOCATION_ZOOM = 11
    WORLD_ZOOM = 1

    # GET /location
    def show
      @location = present
    end

    # POST /location
    #
    # Answers with the newly geocoded place rather than a redirect: the only caller is the map's
    # fetch, and the page updates its heading in place instead of reloading.
    def create
      coordinates = Location.parse(params[:latitude], params[:longitude])
      return head :unprocessable_content if coordinates.nil?

      Location.store(*coordinates)
      render json: described(coordinates)
    end

    private

    def present
      LocationPresenter.new(
        stored: Location.stored,
        override: Location.override,
        map_token: ENV["MAPBOX_ACCESS_TOKEN"],
        map_style: MAP_STYLE,
        location_zoom: LOCATION_ZOOM,
        world_zoom: WORLD_ZOOM,
        save_path: location_path,
        **described(Location.override || Location.stored)
      )
    end

    # The place name and time zone as the **weather widget** derives them, which is what makes this
    # page a preview of how a location will read there.
    #
    # ⚠️ Same path as Widgets::WeatherController: format_location over GoogleMaps#location, plus
    # TimeZoneResolver's default. Don't reach for LocationContext#label instead — it adds fallbacks
    # ("Current location") the widget doesn't have, so the preview would promise a name the widget
    # would never print. Degrades to nothing, so an unset GOOGLE_API_KEY leaves coordinates alone.
    # @return [Hash] :place and :time_zone, both possibly nil.
    def described(coordinates)
      return { place: nil, time_zone: nil } if coordinates.nil?

      gmaps = GoogleMaps.new(*coordinates)
      {
        place: helpers.format_location(DeepOstruct.wrap(gmaps.location)).presence,
        time_zone: gmaps.time_zone_id || TimeZoneResolver.default
      }
    rescue StandardError => e
      Rails.logger.warn("Location: could not describe #{coordinates.inspect} (#{e.class}: #{e.message})")
      { place: nil, time_zone: nil }
    end
  end
end
