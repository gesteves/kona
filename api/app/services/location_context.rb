# Resolves a coordinate pair to the geographic context the location sync pushes to
# Intervals.icu: a display label, a "city, state, country" location string, the individual
# city/state/country fields, and the IANA timezone. Faithful port of domestique's
# resolveLocationContext (which was itself originally ported from this app). Reuses GoogleMaps
# for the reverse-geocode + timezone and LocationHelper#format_location for the label — the same
# label builder the weather widgets use — so the label special cases stay in one place.
class LocationContext
  include LocationHelper

  # Fallback label when geocoding yields nothing usable.
  DEFAULT_LABEL = "Current location".freeze

  attr_reader :latitude, :longitude
  alias_method :lat, :latitude
  alias_method :lon, :longitude

  # @param latitude [Float]
  # @param longitude [Float]
  def initialize(latitude, longitude)
    @latitude = latitude
    @longitude = longitude
    @gmaps = GoogleMaps.new(latitude, longitude)
  end

  # Human-readable display label, e.g. "Jackson Hole, Wyoming". Never blank.
  # @return [String]
  def label
    @label ||= format_location(DeepOstruct.wrap(geocoded: geocoded)).presence ||
               geocoded&.dig(:formatted_address).presence ||
               DEFAULT_LABEL
  end

  # "city, state, country" (with the obfuscated city), falling back to the label.
  # @return [String]
  def location
    @location ||= [ city, state, country ].compact_blank.join(", ").presence || label
  end

  # The city, using a broader lookup than the label's (locality → sublocality → the two admin
  # levels) and obfuscating a precise Teton County location to "Jackson Hole".
  # @return [String, nil]
  def city
    return @city if defined?(@city)

    resolved = component_long_name("locality") ||
               component_long_name("sublocality") ||
               component_long_name("administrative_area_level_3") ||
               component_long_name("administrative_area_level_2")
    @city = (county == "Teton County" && state == "Wyoming") ? "Jackson Hole" : resolved
  end

  # @return [String, nil]
  def state
    return @state if defined?(@state)

    @state = component_long_name("administrative_area_level_1")
  end

  # @return [String, nil]
  def country
    return @country if defined?(@country)

    @country = component_long_name("country")
  end

  # The IANA timezone id, or nil when the lookup is unavailable — nil is left unwritten (never
  # forced to a default), so a failed lookup doesn't overwrite the athlete's real timezone.
  # @return [String, nil]
  def timezone
    return @timezone if defined?(@timezone)

    @timezone = @gmaps.time_zone_id
  end

  private

  def county
    return @county if defined?(@county)

    @county = component_long_name("administrative_area_level_2")
  end

  # The long_name of the first geocoded address component whose types include `type`, or nil.
  def component_long_name(type)
    components.find { |component| component[:types]&.include?(type) }&.dig(:long_name).presence
  end

  def components
    geocoded&.dig(:address_components) || []
  end

  def geocoded
    return @geocoded if defined?(@geocoded)

    @geocoded = @gmaps.geocoded
  end
end
