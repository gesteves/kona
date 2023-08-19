module LocationHelpers
  def format_location
    components = data.location['results'][0]['address_components']

    # Extract city, state, and country names from the components
    city = components.find { |component| component['types'].include?('locality') }['long_name']
    state = components.find { |component| component['types'].include?('administrative_area_level_1') }['long_name']
    country = components.find { |component| component['types'].include?('country') }['long_name']

    # Replace single quotes with curly single quotes, so places like "Coeur d’Alene" look right
    city.gsub!("'", "’")
    state.gsub!("'", "’")
    country.gsub!("'", "’")

    case country
    when 'United States', 'United Kingdom'
      if city == 'New York' && state == 'New York'
        return 'New York City'
      elsif state == 'District of Columbia'
        return 'Washington, DC'
      else
        return "#{city}, #{state}"
      end
    else
      if city.downcase =~ /#{country.downcase}/
        return city
      else
        return "#{city}, #{country}"
      end
    end
  end


end