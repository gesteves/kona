module WeatherHelpers
  PRECIPITATION_UNITS = {
    unit: 'mm',
    ten: 'cm',
    thousand: 'm'
  }

  def format_temperature(temp)
    "#{number_to_human(temp, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºC"
  end

  def is_daytime?
    now = Time.now
    sunrise = Time.parse(data.weather.forecastDaily.days.first.sunrise)
    sunset = Time.parse(data.weather.forecastDaily.days.first.sunset)
    now > (sunrise - 1.hour) && now < (sunset - 1.hour)
  rescue
    true
  end

  def today_or_tonight
    is_daytime? ? "Today" : "Tonight"
  end

  def format_precipitation(amount)
    number_to_human(amount, units: PRECIPITATION_UNITS, precision: 2, strip_insignificant_zeros: true, significant: false, delimiter: ',')
  end

  def format_condition(condition_code)
    data.conditions.dig(condition_code, :description) || condition_code.underscore.gsub('_', ' ')
  end

  def format_current_condition(condition_code)
    data.conditions.dig(condition_code, :current) || format_condition(condition_code)
  end

  def format_forecasted_condition(condition_code)
    data.conditions.dig(condition_code, :forecast) || format_condition(condition_code)
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
    return !data.conditions.dig(data.weather.currentWeather.conditionCode, :safe)
    return !data.conditions.dig(data.weather.forecastDaily.days.first.conditionCode, :safe)
    return true if data.weather.forecastDaily.days.first.temperatureMax >= 32
    return true if data.weather.forecastDaily.days.first.temperatureMin <= -12
    return true if data.weather.forecastDaily.days.first.restOfDayForecast.precipitationChance >= 0.5
    return true if data.weather.forecastDaily.days.first.restOfDayForecast.snowfallAmount > 0
  end

  def aqi_quality
    case data.purple_air.aqi.value
    when 0..50
      "a good"
    when 50..100
      "a moderate"
    when 100..200
      "an unhealthy"
    when 200..300
      "a _very_ unhealthy"
    else
      "a **hazardous**"
    end
  end

  def is_hot?
    data.weather.currentWeather.temperature >= 32 || data.weather.currentWeather.temperatureApparent >= 32
  end

  def forecast
    weather = ""
    weather += "**It's race day!** " if is_race_day?
    weather += "Man, it's a hot one! " if !is_race_day? && is_hot?
    weather += "I'm currently in **#{format_location}**, where"
    weather += " #{format_current_condition(data.weather.currentWeather.conditionCode).downcase}, with a temperature of #{format_temperature(data.weather.currentWeather.temperature)}"
    weather += " (which feels like #{format_temperature(data.weather.currentWeather.temperatureApparent)})" if data.weather.currentWeather.temperature.round != data.weather.currentWeather.temperatureApparent.round
    weather += " and #{aqi_quality} <abbr title=\"Air Quality Index\">AQI</abbr> of #{data.purple_air.aqi.value.round}" if data&.purple_air&.aqi&.value.present?

    if data.weather.forecastDaily.present?
      day = data.weather.forecastDaily.days.first
      weather += ". #{today_or_tonight}'s forecast calls for #{format_forecasted_condition(day.restOfDayForecast.conditionCode).downcase},"
      weather += " with a high of #{format_temperature(day.temperatureMax)}"
      weather += day.precipitationChance == 0 || day.restOfDayForecast.precipitationType.downcase == 'clear' ? " and " : ", "
      weather += " a low of #{format_temperature(day.temperatureMin)}"
      weather += ", and #{number_to_percentage(day.restOfDayForecast.precipitationChance * 100, precision: 0)} chance of #{format_precipitation(day.restOfDayForecast.precipitationType)}" if day.restOfDayForecast.precipitationChance > 0 && day.restOfDayForecast.precipitationType.downcase != 'clear'
      weather += ", with #{format_precipitation(day.restOfDayForecast.snowfallAmount)} of snow expected" if day.restOfDayForecast.snowfallAmount > 0
      weather += "."
    end

    if is_daytime?
      if is_rest_day?
        weather += " It's a good day to rest!"
      elsif !is_race_day?
        weather += " It's a good day to train "
        weather += train_indoors? ? "indoors!" : "outside!"
      end
    end

    markdown_to_html(weather)
  end

  def weather_icon
    condition = data.conditions[data.weather.currentWeather.conditionCode]
    return 'cloud-question' if condition.blank?
    if data.weather.currentWeather.daylight
      condition[:icon_day] || condition[:icon]
    else
      condition[:icon_night] || condition[:icon]
    end
  end
end
