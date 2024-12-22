require 'active_support/all'
module LocationHelpers
  # Formats location information based on address components from the Google Maps API.
  # Handles special formatting for some specific locations.
  # @see https://developers.google.com/maps/documentation/geocoding/requests-geocoding#GeocodingResponses
  # @return [String] The formatted location string.
  def format_location
    components = data.location.geocoded.address_components

    # Extract city, state/region, and country names from the components
    city = components.find { |component| component.types.include?('locality') }&.long_name || components.find { |component| component.types.include?('sublocality') }&.long_name
    region = components.find { |component| component.types.include?('administrative_area_level_1') }&.long_name
    county = components.find { |component| component.types.include?('administrative_area_level_2') }&.long_name
    country = components.find { |component| component.types.include?('country') }&.long_name

    # Replace single quotes with curly single quotes, so places like "Coeur d’Alene" look right.
    # (For whatever reason, SmartyPants can't handle this).
    city&.gsub!("'", "’")
    region&.gsub!("'", "’")
    county&.gsub!("'", "’")
    country&.gsub!("'", "’")

    # No need to be more specific than this when I'm home 😬
    return 'Jackson Hole, Wyoming' if county == 'Teton County' && region == 'Wyoming'
    # "New York, New York" is kinda redundant, so...
    return 'New York City' if city == 'New York' && region == 'New York'
    # DC is the only case where I want the state abbreviation.
    return 'Washington, DC' if region == 'District of Columbia'
    # Not sure how to get Google Maps to return translated names.
    return 'Mexico City, Mexico' if city == 'Ciudad de México'

    case country
    when 'United States'
      # The US gets city (or county) and state, e.g.
      # - San Francisco, California
      # - Fairfax County, Virginia
      return [city || county, region].compact.join(", ")
    when 'United Kingdom', 'Canada'
      # The UK and Canada get city and province/region, e.g.
      # - Edinburgh, Scotland
      # - Vancouver, British Columbia
      return [city, region].compact.join(", ")
    else
      # Every other country gets city and country, e.g.
      # - Caracas, Venezuela
      return [city, country].compact.join(", ")
    end
  end

  # Returns the elevation for the current location formatted in meters and feet.
  # @return [String] A formatted elevation value with units in both meters and feet.
  def format_elevation
    elevation = data.location.elevation
    return if elevation.blank?
    meters = "#{number_to_rounded(elevation, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')} m"
    feet = number_to_rounded(meters_to_feet(elevation), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')
    feet = feet == "1" ? "#{feet} foot" : "#{feet} feet"
    units_tag(meters, feet)
  end

  # Checks if the location is, well, Jackson Hole.
  # @return [Boolean] True if the location matches, false otherwise.
  def in_jackson_hole?
    format_location == 'Jackson Hole, Wyoming'
  end

  # Returns the time zone ID for the current location.
  # @return [String] A time zone ID, of rhte
  def location_time_zone
    data&.location&.time_zone&.time_zone_id || 'America/Denver'
  end

  # Returns the current time in the current location's time zone
  # @return [DateTime] The current time in the local time zone
  def current_time
    Time.current.in_time_zone(location_time_zone)
  end
end
