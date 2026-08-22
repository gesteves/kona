module Admin
  # The current location: a map for a pin, an address box, and a shortcut for each upcoming race.
  # All three only **stage** a location. `create` is the one action that writes, and it writes the
  # same Redis key as the POST /api/location that needs a bearer token, through the same
  # Location.store. Thus this is a front end for the write that already exists, and not a second
  # way to store a location.
  class LocationController < BaseController
    # The base map for the selection of a place.
    #
    # ⚠️ This is not MAPBOX_STYLE_URL, on purpose. That variable names the default style for a *GPX
    # render*, where a custom style is the purpose. Here it would give a base map for a race photo,
    # with no streets and no labels, and this page exists to read those.
    MAP_STYLE = "mapbox://styles/mapbox/streets-v12".freeze

    # The zoom levels: near enough to know a neighborhood, or the full world when there is no
    # location at the center.
    LOCATION_ZOOM = 11
    WORLD_ZOOM = 1

    # GET /location
    def show
      @location = present
    end

    # GET /location/lookup
    #
    # Finds the location that the page is *ready* to save, and saves nothing: an `address` to
    # geocode, or a pair of coordinates to name. This is what lets a pin, a race shortcut, or a
    # search show its name below the heading before someone presses the Save button.
    #
    # ⚠️ This must never write. It is the half of this page that anyone can use as much as they
    # want, and the purpose of the Save button is that nothing before it changes what the widgets
    # read.
    def lookup
      coordinates = requested_coordinates
      return head :unprocessable_content if coordinates.nil?

      render json: located(coordinates)
    end

    # POST /location
    #
    # Saves a staged pair of coordinates. It takes **coordinates only**, on purpose. `lookup`
    # resolves an address first, thus this action stores one shape of data and one place decides
    # what a correct location is.
    #
    # It answers with the place and not with a redirect: the only caller is the fetch of the page,
    # and that fetch changes the heading in place and does not load the page again.
    def create
      coordinates = Location.parse(params[:latitude], params[:longitude])
      return head :unprocessable_content if coordinates.nil?

      Location.store(*coordinates)
      render json: located(coordinates)
    end

    private

    # @return [Hash] The pair that the page uses, and the name of that location.
    def located(coordinates)
      { latitude: coordinates.first, longitude: coordinates.last, **described(coordinates) }
    end

    # ⚠️ A pair of coordinates has the highest importance when one of the two values is available,
    # even when the pair is incorrect. A change to the address for a bad pair would save a place
    # that the caller did not ask for.
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

    # The place name, as the **weather widget** makes it. That is what makes this page a preview of
    # the name in that widget.
    #
    # ⚠️ This is the same path as in Widgets::WeatherController: format_location over
    # GoogleMaps#location. Do not use LocationContext#label. That method adds other names
    # ("Current location") that the widget does not have, thus the preview would show a name that
    # the widget would never show. This method gives nothing on a failure, thus a GOOGLE_API_KEY
    # with no value leaves the coordinates.
    # @return [Hash] :place, which can be nil.
    def described(coordinates)
      return { place: nil } if coordinates.nil?

      { place: helpers.format_location(DeepOstruct.wrap(GoogleMaps.new(*coordinates).location)).presence }
    rescue StandardError => e
      Rails.logger.warn("Location: could not describe #{coordinates.inspect} (#{e.class}: #{e.message})")
      { place: nil }
    end
  end
end
