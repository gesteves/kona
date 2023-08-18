module LocationHelpers
  def format_location
    components = data.location['results'][0]['address_components']
    city = components.find { |component| component['types'].include?('locality') }['long_name']
    region = components.find { |component| component['types'].include?('administrative_area_level_1') }['long_name']
    country = components.find { |component| component['types'].include?('country') }['long_name']

    if country == 'United States' || country == 'Canada'
      "#{city}, #{region}"
    else
      "#{city}, #{country}"
    end
  end
end
