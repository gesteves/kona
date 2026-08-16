# Presents the current location for the admin's Location page: what's stored, what (if anything)
# is overriding it, and the values the map is initialized from.
#
# Both coordinate pairs are passed in rather than read here, and the place name is resolved by the
# controller, so the view stays free of service calls — same rule as ConnectedAccountPresenter.
class LocationPresenter
  # Where the map looks when there's nothing to center on: the whole world, tilted north so the
  # landmasses aren't split across the bottom edge.
  WORLD_CENTER = [ 0, 20 ].freeze

  attr_reader :place, :time_zone, :map_token, :map_style, :save_path

  # @param stored [Array(Float, Float), nil] The coordinates in Redis.
  # @param override [Array(Float, Float), nil] The LOCATION env var, which outranks them.
  # @param place [String, nil] The name the weather widget would print for this location.
  # @param time_zone [String, nil] The time zone the widgets would use.
  # @param map_token [String, nil] The **public** Mapbox token.
  # @param map_style [String] The basemap style URL.
  # @param location_zoom [Integer] Zoom to use when there's a location.
  # @param world_zoom [Integer] Zoom to use when there isn't.
  # @param save_path [String] Where a pin drop posts.
  def initialize(stored:, override:, place:, time_zone:, map_token:, map_style:,
                 location_zoom:, world_zoom:, save_path:)
    @stored = stored
    @override = override
    @place = place
    @time_zone = time_zone
    @map_token = map_token
    @map_style = map_style
    @location_zoom = location_zoom
    @world_zoom = world_zoom
    @save_path = save_path
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
    coordinates&.join(", ")
  end

  # The headline: the name the weather widget would print. Falls back to the coordinates rather
  # than to a placeholder, since a geocode that resolves to nothing is exactly what the widget
  # would show as a blank — and the page shouldn't be blank about it.
  # @return [String]
  def heading
    @place.presence || summary || "Nowhere yet"
  end

  # @return [String] The line under the heading: where it is, and which clock the widgets keep.
  def details
    return "Drop a pin on the map to set your location." unless set?

    [ summary, @time_zone ].compact_blank.join(" · ")
  end

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
end
