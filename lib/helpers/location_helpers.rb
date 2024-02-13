module LocationHelpers
  # Formats location information based on address components from the Google Maps API.
  # Handles special formatting for some specific locations.
  # @see https://developers.google.com/maps/documentation/geocoding/requests-geocoding#GeocodingResponses
  # @return [String] The formatted location string.
  def format_location
    components = data.location.results.first.address_components

    # Extract city, state/region, and country names from the components
    city = components.find { |component| component['types'].include?('locality') }&.long_name
    region = components.find { |component| component['types'].include?('administrative_area_level_1') }&.long_name
    county = components.find { |component| component['types'].include?('administrative_area_level_2') }&.long_name
    country = components.find { |component| component['types'].include?('country') }&.long_name

    # Replace single quotes with curly single quotes, so places like "Coeur d’Alene" look right
    city&.gsub!("'", "’")
    region&.gsub!("'", "’")
    county&.gsub!("'", "’")
    country&.gsub!("'", "’")

    case country
    when 'United States', 'United Kingdom', 'Canada'
      if city == 'New York' && region == 'New York'
        return 'New York City'
      elsif region == 'District of Columbia'
        return 'Washington, DC'
      elsif county == 'Teton County' && region == 'Wyoming'
        return 'Jackson Hole, Wyoming'
      else
        return [city || county, region].compact.join(", ")
      end
    else
      if city == 'Ciudad de México'
        return 'Mexico City'
      else
        return [city || region, country].compact.join(", ")
      end
    end
  end

  # Checks if the location is, well, Jackson Hole.
  # @return [Boolean] True if the location matches, false otherwise.
  def in_jackson_hole?
    format_location == 'Jackson Hole, Wyoming'
  end
end
