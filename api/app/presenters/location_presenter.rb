# Presents the current location for the Location page of the admin: the stored location, the
# value that replaces it if there is one, the values that the map starts with, and the upcoming
# races that the page offers as one-click shortcuts.
#
# The caller gives the coordinate pairs and the raw events, and this class does not read them. The
# controller finds the place name. Thus the view makes no service call. ConnectedAppPresenter has
# the same rule.
class LocationPresenter
  # For parse_event_date, thus "upcoming" has the same meaning as in the races widget.
  include EventsHelper

  # The map view when there is no location at the center: the full world, moved to the north, thus
  # the bottom edge does not cut the land.
  WORLD_CENTER = [ 0, 20 ].freeze

  # The code rounds the coordinates on the screen to this number of decimals, which is
  # approximately 110m. That is sufficient for a "where am I" reading. The code stores the value
  # from the pin. This applies only to the screen.
  DISPLAY_PRECISION = 3

  # One upcoming race, with only the data that the shortcut list shows and that its button posts.
  Race = Data.define(:title, :place, :date, :latitude, :longitude) do
    # @return [String] The date, in the same format as the race cards of the site.
    def on
      date.strftime("%B %-e, %Y")
    end
  end

  attr_reader :place, :map_token, :map_style, :save_path, :lookup_path

  # @param stored [Array(Float, Float), nil] The coordinates in Redis.
  # @param override [Array(Float, Float), nil] The LOCATION env var, which replaces them.
  # @param place [String, nil] The name that the weather widget would show for this location.
  # @param events [Array<OpenStruct>] All the Contentful events. {#races} selects from them.
  # @param time_zone [String] The IANA timezone that decides which races are ahead.
  # @param map_token [String, nil] The **public** Mapbox token.
  # @param map_style [String] The URL of the base map style.
  # @param location_zoom [Integer] The zoom for a page with a location.
  # @param world_zoom [Integer] The zoom for a page with no location.
  # @param save_path [String] The path that Save posts to.
  # @param lookup_path [String] The path where the page finds a staged location. It saves
  #   nothing.
  def initialize(stored:, override:, place:, events:, time_zone:, map_token:, map_style:,
                 location_zoom:, world_zoom:, save_path:, lookup_path:)
    @stored = stored
    @override = override
    @place = place
    @events = events || []
    @time_zone = time_zone
    @map_token = map_token
    @map_style = map_style
    @location_zoom = location_zoom
    @world_zoom = world_zoom
    @save_path = save_path
    @lookup_path = lookup_path
  end

  # The coordinates that apply now. If there is a replacement value, it is that value.
  # @return [Array(Float, Float), nil]
  def coordinates
    @override || @stored
  end

  # @return [Float, nil]
  def latitude
    coordinates&.first
  end

  # @return [Float, nil]
  def longitude
    coordinates&.last
  end

  # @return [String, nil] The two coordinates, for the screen.
  def summary
    coordinates&.map { |value| value.round(DISPLAY_PRECISION) }&.join(", ")
  end

  # The heading: the name that the weather widget would show. If there is no name, it gives the
  # coordinates and not a placeholder. A geocode that finds nothing is what the widget would show
  # as a blank, and this page must not be blank about it.
  # @return [String]
  def heading
    @place.presence || summary || "Nowhere yet"
  end

  # @return [String] The line below the heading: the location. The tag beside it says if the app
  #   stored that location.
  def details
    return "Drop a pin on the map to set your location." unless set?

    summary
  end

  # The state of the tag at the first render. It is always "saved" when there is a location,
  # because nothing can be staged before the page loads.
  #
  # ⚠️ Its equivalent is STATES in location_map_controller.js, which controls each change after
  # that. The two sets of words must agree.
  # @return [String]
  def state_label
    set? ? "Saved" : "Not set"
  end

  # @return [String] The wa-badge variant for {#state_label}, as on the Connected apps page and
  #   the Course maps page.
  def state_variant
    set? ? "success" : "neutral"
  end

  # ⚠️ This is NOT rounded, on purpose, and `summary` is different. It shows the value from the
  # environment, thus you can compare it with the true value there.
  # @return [String, nil] The coordinates that replace the stored ones, for the callout.
  def override_summary
    @override&.join(", ")
  end

  # @return [Boolean] True if there is any value.
  def set?
    coordinates.present?
  end

  # ⚠️ When this is true, a pin still writes to Redis but changes nothing that a widget reads,
  # because Location uses the env var first. The page says so and does not look like it works.
  # @return [Boolean]
  def overridden?
    @override.present?
  end

  # @return [Boolean] True if the code can render the browser map.
  def configured?
    @map_token.present?
  end

  # @return [Array(Float, Float)] The center of the map, with the longitude first, as Mapbox
  #   needs.
  def center
    set? ? [ longitude, latitude ] : WORLD_CENTER
  end

  # @return [Integer]
  def zoom
    set? ? @location_zoom : @world_zoom
  end

  # The races that are ahead, the soonest first. They are the "I'm at this one" shortcuts of the
  # page.
  #
  # ⚠️ This is not EventsHelper#upcoming_races, on purpose. That is the *selection* of the widget,
  # with a maximum of three or four races. Each confirmed race that is ahead belongs here. The code
  # removes a race with no coordinates and does not show a button that cannot move the map.
  # @return [Array<Race>]
  def races
    @races ||= @events.filter_map { |event| race(event) }.sort_by(&:date)
  end

  private

  # @return [Race, nil] The event as a shortcut, or nil if it is not a shortcut.
  def race(event)
    return unless event.going

    date = parse_event_date(event, @time_zone)
    return if date.nil? || date < today

    coordinates = Location.parse(event.coordinates&.lat, event.coordinates&.lon)
    return if coordinates.nil?

    Race.new(title: event.title, place: event.location, date: date,
             latitude: coordinates.first, longitude: coordinates.last)
  end

  def today
    @today ||= Time.current.in_time_zone(@time_zone).to_date
  end
end
