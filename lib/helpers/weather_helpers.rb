module WeatherHelpers
  PRECIPITATION_UNITS = {
    unit: 'mm',
    ten: 'cm',
    thousand: 'm'
  }

  CONDITIONS = {
    "Clear" => {
      :description => "Clear", :icon_day => "sun", :icon_night => "moon"
    },
    "Cloudy" => {
      :description => "Cloudy", :icon => "clouds"
    },
    "Dust" => {
      :description => "Dust", :icon => "sun-dust"
    },
    "Fog" => {
      :description => "Fog", :icon => "cloud-fog"
    },
    "Haze" => {
      :description => "Haze", :icon => "sun-haze"
    },
    "MostlyClear" => {
      :description => "Mostly Clear", :icon_day => "sun-cloud", :icon_night => "moon-cloud"
    },
    "MostlyCloudy" => {
      :description => "Mostly Cloudy", :icon_day => "clouds-sun", :icon_night => "clouds-sun"
    },
    "PartlyCloudy" => {
      :description => "Partly Cloudy", :icon_day => "clouds-sun", :icon_night => "clouds-sun"
    },
    "ScatteredThunderstorms" => {
      :description => "Scattered Thunderstorms", :icon => "cloud-bolt"
    },
    "Smoke" => {
      :description => "Smoke", :icon => "smoke"
    },
    "Breezy" => {
      :description => "Breezy", :icon => "wind"
    },
    "Windy" => {
      :description => "Windy", :icon => "wind"
    },
    "Drizzle" => {
      :description => "Drizzle", :icon => "cloud-drizzle"
    },
    "HeavyRain" => {
      :description => "Heavy Rain", :icon => "cloud-showers-heavy"
    },
    "Rain" => {
      :description => "Rain", :icon => "cloud-rain"
    },
    "Showers" => {
      :description => "Showers", :icon => "cloud-showers"
    },
    "Flurries" => {
      :description => "Flurries", :icon => "cloud-snow"
    },
    "HeavySnow" => {
      :description => "Heavy Snow", :icon => "cloud-snow"
    },
    "MixedRainAndSleet" => {
      :description => "Mixed Rain and Sleet", :icon => "cloud-hail-mixed"
    },
    "MixedRainAndSnow" => {
      :description => "Mixed Rain and Snow", :icon => "cloud-hail-mixed"
    },
    "MixedRainfall" => {
      :description => "Mixed Rainfall", :icon => "cloud-hail-mixed"
    },
    "MixedSnowAndSleet" => {
      :description => "Mixed Snow and Sleet", :icon => "cloud-hail-mixed"
    },
    "ScatteredShowers" => {
      :description => "Scattered Showers", :icon => "cloud-showers"
    },
    "ScatteredSnowShowers" => {
      :description => "Scattered Snow Showers", :icon => "cloud-snow"
    },
    "Sleet" => {
      :description => "Sleet", :icon => "cloud-snow"
    },
    "Snow" => {
      :description => "Snow", :icon => "cloud-snow"
    },
    "SnowShowers" => {
      :description => "Snow Showers", :icon => "cloud-hail-mixed"
    },
    "Blizzard" => {
      :description => "Blizzard", :icon => "snow-blowing"
    },
    "BlowingSnow" => {
      :description => "Blowing Snow", :icon => "snow-blowing"
    },
    "FreezingDrizzle" => {
      :description => "Freezing Drizzle", :icon => "cloud-hail-mixed"
    },
    "FreezingRain" => {
      :description => "Freezing Rain", :icon => "cloud-hail-mixed"
    },
    "Frigid" => {
      :description => "Frigid", :icon => "temperature-snow"
    },
    "Hail" => {
      :description => "Hail", :icon => "cloud-hail"
    },
    "Hot" => {
      :description => "Hot", :icon => "temperature-sun"
    },
    "Hurricane" => {
      :description => "Hurricane", :icon => "hurricane"
    },
    "IsolatedThunderstorms" => {
      :description => "Isolated Thunderstorms", :icon => "cloud-bolt"
    },
    "SevereThunderstorm" => {
      :description => "Severe Thunderstorm", :icon => "cloud-bolt"
    },
    "Thunderstorm" => {
      :description => "Thunderstorm", :icon => "cloud-bolt"
    },
    "Tornado" => {
      :description => "Tornado", :icon => "tornado"
    },
    "TropicalStorm" => {
      :description => "Tropical Storm", :icon => "hurricane"
    }
  }

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

  def format_temperature(temp)
    "#{number_to_human(temp, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºC"
  end

  def today_or_tonight(daylight)
    daylight.presence ? "Today" : "Tonight"
  end

  def format_precipitation(amount)
    number_to_human(amount, units: PRECIPITATION_UNITS, precision: 2, strip_insignificant_zeros: true, significant: false, delimiter: ',')
  end

  def format_condition(condition_code)
    CONDITIONS.dig(condition_code, :description)
  end

  def format_precipitation(type)
    case type.downcase
    when 'clear'
      'precipitation'
    when 'mixed'
      'wintry mix'
    else
      type.downcase
    end
  end

  def train_indoors?
    return true if data.purple_air&.aqi&.value&.to_i > 75
    return true if data.weather.forecastDaily.days.first.temperatureMax >= 32
    return true if data.weather.forecastDaily.days.first.temperatureMin <= -12
    return true if data.weather.forecastDaily.days.first.precipitationChance >= 0.5
    return ["Dust", "ScatteredThunderstorms", "Smoke", "HeavyRain", "Rain", "Showers", "HeavySnow",
      "MixedRainAndSleet", "MixedRainAndSnow", "MixedRainfall", "MixedSnowAndSleet",
      "ScatteredShowers", "ScatteredSnowShowers", "Sleet", "Snow", "SnowShowers",
      "Blizzard", "BlowingSnow", "FreezingDrizzle", "FreezingRain", "Frigid",
      "Hail", "Hot", "Hurricane", "IsolatedThunderstorms", "SevereThunderstorm",
      "Thunderstorm", "Tornado", "TropicalStorm"].include?(data.weather.forecastDaily.days.first.conditionCode)
  end

  def aqi_quality(aqi)
    case aqi
    when 0..25
      "_great_"
    when 25..50
      "good"
    when 50..100
      "moderate"
    when 100..150
      "bad"
    when 150..200
      "_terrible_"
    else
      "**horrible**"
    end
  end

  def is_hot?
    data.weather.currentWeather.temperature >= 32 || data.weather.currentWeather.temperatureApparent >= 32
  end

  def forecast
    weather = ""
    weather += "**It's race day!** " if is_race_day?
    weather += "Man, it's a hot one! " if !is_race_day? && is_hot?
    weather += "I'm currently in **#{format_location}**, where the weather is"
    weather += " #{format_condition(data.weather.currentWeather.conditionCode).downcase}, with a temperature of #{format_temperature(data.weather.currentWeather.temperature)}"
    weather += " (which feels like #{format_temperature(data.weather.currentWeather.temperatureApparent)})" if data.weather.currentWeather.temperature.round != data.weather.currentWeather.temperatureApparent.round
    weather += " and a #{aqi_quality(data.purple_air.aqi.value)} <abbr title=\"Air Quality Index\">AQI</abbr> of #{data.purple_air.aqi.value.round}" if data&.purple_air&.aqi&.value.present?

    if data.weather.forecastDaily.present?
      weather += ". #{today_or_tonight(data.weather.currentWeather.daylight)}'s forecast is #{format_condition(data.weather.forecastDaily.days.first.restOfDayForecast.conditionCode).downcase},"
      weather += " with a high of #{format_temperature(data.weather.forecastDaily.days.first.temperatureMax)}"
      weather += data.weather.forecastDaily.days.first.precipitationChance == 0 || data.weather.forecastDaily.days.first.restOfDayForecast.precipitationType.downcase == 'clear' ? " and " : ", "
      weather += " a low of #{format_temperature(data.weather.forecastDaily.days.first.temperatureMin)}"
      weather += ", and a #{number_to_percentage(data.weather.forecastDaily.days.first.restOfDayForecast.precipitationChance * 100, precision: 0)} chance of #{format_precipitation(data.weather.forecastDaily.days.first.restOfDayForecast.precipitationType)}" if data.weather.forecastDaily.days.first.restOfDayForecast.precipitationChance > 0 && data.weather.forecastDaily.days.first.restOfDayForecast.precipitationType.downcase != 'clear'
      weather += ", with #{format_precipitation(data.weather.forecastDaily.days.first.restOfDayForecast.snowfallAmount)} of snow expected" if data.weather.forecastDaily.days.first.restOfDayForecast.snowfallAmount > 0
      weather += "."
    end

    if data.weather.currentWeather.daylight && !is_race_day?
      weather += " It's a good day to train "
      weather += train_indoors? ? "indoors!" : "outside!"
    end

    markdown_to_html(weather)
  end

  def weather_icon
    condition = CONDITIONS[data.weather.currentWeather.conditionCode]
    return 'cloud-question' if condition.blank?
    if data.weather.currentWeather.daylight
      condition[:icon_day] || condition[:icon]
    else
      condition[:icon_night] || condition[:icon]
    end
  end
end
