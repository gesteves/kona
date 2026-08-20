# Presents the current location for the admin's Location page: what's stored, what (if anything)
# is overriding it, the values the map is initialized from, and the upcoming races the page offers
# as one-click shortcuts.
#
# The coordinate pairs and the raw events are passed in rather than read here, and the place name
# is resolved by the controller, so the view stays free of service calls — same rule as
# ConnectedAppPresenter.
class LocationPresenter
  # For parse_event_date, so "upcoming" is reckoned the same way the races widget reckons it.
  include EventsHelper

  # Where the map looks when there's nothing to center on: the whole world, tilted north so the
  # landmasses aren't split across the bottom edge.
  WORLD_CENTER = [ 0, 20 ].freeze

  # Displayed coordinates are rounded to this many decimals — ~110m, which is as fine as a "where
  # am I" reading needs to read. What gets stored is whatever was dropped; this is display only.
  DISPLAY_PRECISION = 3

  # One upcoming race, reduced to what the shortcut list shows and what its button posts.
  Race = Data.define(:title, :place, :date, :latitude, :longitude) do
    # @return [String] The date, formatted as the site's own race cards format it.
    def on
      date.strftime("%B %-e, %Y")
    end
  end

  attr_reader :place, :map_token, :map_style, :save_path, :lookup_path

  # @param stored [Array(Float, Float), nil] The coordinates in Redis.
  # @param override [Array(Float, Float), nil] The LOCATION env var, which outranks them.
  # @param place [String, nil] The name the weather widget would print for this location.
  # @param events [Array<OpenStruct>] Every Contentful event, filtered down by {#races}.
  # @param time_zone [String] The IANA timezone that decides which races are still ahead.
  # @param map_token [String, nil] The **public** Mapbox token.
  # @param map_style [String] The basemap style URL.
  # @param location_zoom [Integer] Zoom to use when there's a location.
  # @param world_zoom [Integer] Zoom to use when there isn't.
  # @param save_path [String] Where Save changes posts.
  # @param lookup_path [String] Where the page resolves a staged location, without saving it.
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

  # The coordinates in effect, which is the override where there is one.
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

  # @return [String, nil] Both coordinates, for display.
  def summary
    coordinates&.map { |value| value.round(DISPLAY_PRECISION) }&.join(", ")
  end

  # The headline: the name the weather widget would print. Falls back to the coordinates rather
  # than to a placeholder, since a geocode that resolves to nothing is exactly what the widget
  # would show as a blank — and the page shouldn't be blank about it.
  # @return [String]
  def heading
    @place.presence || summary || "Nowhere yet"
  end

  # @return [String] The line under the heading: where it is. The tag beside it says whether that
  #   location is stored yet.
  def details
    return "Drop a pin on the map to set your location." unless set?

    summary
  end

  # The tag's state on arrival, which is always "saved" where there's a location — nothing can be
  # staged before the page has loaded.
  #
  # ⚠️ Its counterpart is STATES in location_map_controller.js, which owns every change after that.
  # The two vocabularies have to stay in step.
  # @return [String]
  def state_label
    set? ? "Saved" : "Not set"
  end

  # @return [String] The wa-badge variant matching {#state_label}, as on Connected apps and
  #   Course maps.
  def state_variant
    set? ? "success" : "neutral"
  end

  # ⚠️ Deliberately NOT rounded, unlike `summary`: this echoes the value configured in the
  # environment so it can be read against what's actually in there.
  # @return [String, nil] The overriding coordinates, for the callout that names them.
  def override_summary
    @override&.join(", ")
  end

  # @return [Boolean] Whether anything is set at all.
  def set?
    coordinates.present?
  end

  # ⚠️ When this is true, dropping a pin still writes Redis but changes nothing any widget reads —
  # Location prefers the env var. The page says so rather than appearing to work.
  # @return [Boolean]
  def overridden?
    @override.present?
  end

  # @return [Boolean] Whether the browser map can be rendered.
  def configured?
    @map_token.present?
  end

  # @return [Array(Float, Float)] Map center, in Mapbox's longitude-first order.
  def center
    set? ? [ longitude, latitude ] : WORLD_CENTER
  end

  # @return [Integer]
  def zoom
    set? ? @location_zoom : @world_zoom
  end

  # The races still ahead, soonest first — the page's "I'm at this one" shortcuts.
  #
  # ⚠️ Deliberately not EventsHelper#upcoming_races: that's the widget's *selection*, capped at
  # three or four. Every confirmed race ahead belongs here. A race without coordinates is dropped
  # rather than listed as a button that couldn't move the map.
  # @return [Array<Race>]
  def races
    @races ||= @events.filter_map { |event| race(event) }.sort_by(&:date)
  end

  private

  # @return [Race, nil] The event as a shortcut, or nil if it isn't one.
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
