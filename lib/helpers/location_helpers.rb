module LocationHelpers
  def format_location
    components = data.location.results.first.address_components

    # Extract city, state, and country names from the components
    city = components.find { |component| component['types'].include?('locality') }&.long_name
    state = components.find { |component| component['types'].include?('administrative_area_level_1') }&.long_name
    county = components.find { |component| component['types'].include?('administrative_area_level_2') }&.long_name
    country = components.find { |component| component['types'].include?('country') }&.long_name

    # Replace single quotes with curly single quotes, so places like "Coeur d’Alene" look right
    city&.gsub!("'", "’")
    state&.gsub!("'", "’")
    county&.gsub!("'", "’")
    country&.gsub!("'", "’")

    case country
    when 'United States', 'United Kingdom'
      if city == 'New York' && state == 'New York'
        return 'New York City'
      elsif state == 'District of Columbia'
        return 'Washington, DC'
      elsif county == 'Teton County' && state == 'Wyoming'
        return "Jackson Hole, Wyoming"
      else
        return [city || county, state].compact.join(", ")
      end
    else
      if city == 'Ciudad de México'
        return city
      else
        return [city || state, country].compact.join(", ")
      end
    end
  end

  def in_jackson_hole?
    format_location == "Jackson Hole, Wyoming"
  end
end
