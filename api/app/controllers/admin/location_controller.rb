module Admin
  # The current location: a map you drop a pin on, an address box, and a shortcut per upcoming
  # race. All three only **stage** a location; `create` is the one thing that writes, and it writes
  # the same Redis key as the bearer-gated POST /api/location, through the same Location.store —
  # so this is a front-end over the write that already existed, not a second way to store a
  # location.
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

    # GET /location/lookup
    #
    # Resolves what the page is *about to* save without saving it: an `address` to geocode, or a
    # coordinate pair to name. This is what lets a pin drop, a race shortcut or a search preview
    # itself under the heading while the Save button is still waiting to be pressed.
    #
    # ⚠️ Must never write. It's the half of this page that can be exercised freely, and the whole
    # point of the Save button is that nothing before it changes what the widgets read.
    def lookup
      coordinates = requested_coordinates
      return head :unprocessable_content if coordinates.nil?

      render json: located(coordinates)
    end

    # POST /location
    #
    # Saves a staged coordinate pair. Deliberately **coordinates only** — an address is resolved by
    # `lookup` first, so there's exactly one shape of thing this stores and one place that decides
    # what a valid location is.
    #
    # Answers with the place rather than a redirect: the only caller is the page's fetch, and it
    # updates the heading in place instead of reloading.
    def create
      coordinates = Location.parse(params[:latitude], params[:longitude])
      return head :unprocessable_content if coordinates.nil?

      Location.store(*coordinates)
      render json: located(coordinates)
    end

    private

    # @return [Hash] The pair the page works in, plus the name it resolves to.
    def located(coordinates)
      { latitude: coordinates.first, longitude: coordinates.last, **described(coordinates) }
    end

    # ⚠️ A coordinate pair wins whenever either half is present, even when the pair is unusable.
    # Falling through to the address on a bad pair would save a place the caller never asked for.
    # @return [Array(Float, Float), nil]
    def requested_coordinates
      if params[:latitude].present? || params[:longitude].present?
        Location.parse(params[:latitude], params[:longitude])
      elsif params[:address].present?
        GoogleGeocoder.new(params[:address]).coordinates
      end
    end

    def present
      LocationPresenter.new(
        stored: Location.stored,
        override: Location.override,
        events: Events.new.all,
        time_zone: TimeZoneResolver.default,
        map_token: ENV["MAPBOX_ACCESS_TOKEN"],
        map_style: MAP_STYLE,
        location_zoom: LOCATION_ZOOM,
        world_zoom: WORLD_ZOOM,
        save_path: location_path,
        lookup_path: location_lookup_path,
        **described(Location.override || Location.stored)
      )
    end

    # The place name as the **weather widget** derives it, which is what makes this page a preview
    # of how a location will read there.
    #
    # ⚠️ Same path as Widgets::WeatherController: format_location over GoogleMaps#location. Don't
    # reach for LocationContext#label instead — it adds fallbacks ("Current location") the widget
    # doesn't have, so the preview would promise a name the widget would never print. Degrades to
    # nothing, so an unset GOOGLE_API_KEY leaves coordinates alone.
    # @return [Hash] :place, possibly nil.
    def described(coordinates)
      return { place: nil } if coordinates.nil?

      { place: helpers.format_location(DeepOstruct.wrap(GoogleMaps.new(*coordinates).location)).presence }
    rescue StandardError => e
      Rails.logger.warn("Location: could not describe #{coordinates.inspect} (#{e.class}: #{e.message})")
      { place: nil }
    end
  end
end
