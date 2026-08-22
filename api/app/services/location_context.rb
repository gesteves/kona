# Changes a pair of coordinates into the geographic data that the location sync sends to
# Intervals.icu: a label for the screen, a "city, state, country" string, the separate city, state,
# and country fields, and the IANA timezone. This is the same as resolveLocationContext of
# domestique, which itself came from this app. It uses GoogleMaps for the address and the timezone,
# and LocationHelper#format_location for the label. The weather widgets use that same label method,
# thus each special condition of the label is in one place.
class LocationContext
  include LocationHelper

  # The label to use when the geocoder gives no correct value.
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

  # The label for the screen, for example "Jackson Hole, Wyoming". It is never blank.
  # @return [String]
  def label
    @label ||= format_location(DeepOstruct.wrap(geocoded: geocoded)).presence ||
               geocoded&.dig(:formatted_address).presence ||
               DEFAULT_LABEL
  end

  # "city, state, country", with the city that the code changes. Without those, it gives the
  # label.
  # @return [String]
  def location
    @location ||= [ city, state, country ].compact_blank.join(", ").presence || label
  end

  # The city. This lookup is larger than the lookup of the label: it reads locality, then
  # sublocality, then the two administrative levels. It also changes an exact location in Teton
  # County to "Jackson Hole".
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

  # The IANA timezone id, or nil when the lookup is not available. The code does not write a nil and
  # it never uses a default value. Thus a lookup that fails does not replace the true timezone of the
  # athlete.
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

  # The long_name of the first address component from the geocoder whose types include `type`, or
  # nil.
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
