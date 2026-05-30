module LocationHelper
  # Formats the current location from Google Maps geocoded address components, with a few
  # special cases. Reads the controller-set @location (a dot-accessible GoogleMaps result).
  # @return [String, nil]
  def format_location(location = @location)
    return if location.blank?
    components = location.geocoded&.address_components
    return if components.blank?

    city = components.find { |c| c.types.include?("locality") }&.long_name || components.find { |c| c.types.include?("sublocality") }&.long_name
    region = components.find { |c| c.types.include?("administrative_area_level_1") }&.long_name
    county = components.find { |c| c.types.include?("administrative_area_level_2") }&.long_name
    country = components.find { |c| c.types.include?("country") }&.long_name

    # Curly apostrophes so places like "Coeur d'Alene" look right.
    city = city&.gsub("'", "’")
    region = region&.gsub("'", "’")
    county = county&.gsub("'", "’")
    country = country&.gsub("'", "’")

    return "Jackson Hole, Wyoming" if county == "Teton County" && region == "Wyoming"
    return "New York City" if city == "New York" && region == "New York"
    return "Washington, DC" if region == "District of Columbia"
    return "Mexico City, Mexico" if city == "Ciudad de México"

    case country
    when "United States"
      [city || county, region].compact.join(", ")
    when "United Kingdom", "Canada"
      [city, region].compact.join(", ")
    else
      [city, country].compact.join(", ")
    end
  end

  # Formats the elevation in both meters and feet (with the metric/imperial toggle).
  # @return [String, nil]
  def format_elevation(elevation = @location&.elevation, abbreviated = false)
    return if elevation.blank?
    meters = "#{number_to_rounded(elevation, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')} m"
    feet = number_to_rounded(meters_to_feet(elevation), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ",")
    feet = if abbreviated
      "#{feet} ft"
    else
      feet == "1" ? "#{feet} foot" : "#{feet} feet"
    end
    units_tag(meters, feet)
  end

  def in_jackson_hole?(location = @location)
    format_location(location) == "Jackson Hole, Wyoming"
  end

  def in_san_francisco?(location = @location)
    format_location(location) == "San Francisco, California"
  end
end
