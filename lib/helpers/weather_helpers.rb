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

  def format_precipitation_amount(amount)
    number_to_human(amount, units: PRECIPITATION_UNITS, precision: 2, strip_insignificant_zeros: true, significant: false, delimiter: ',')
  end

  def format_condition(condition_code)
    data.conditions.dig(condition_code, :description) || condition_code.underscore.gsub('_', ' ')
  end

  def format_current_condition(condition_code)
    data.conditions.dig(condition_code, :currently) || format_condition(condition_code)
  end

  def format_forecasted_condition(condition_code)
    data.conditions.dig(condition_code, :forecast) || format_condition(condition_code)
  end

  def format_precipitation_type(type)
    case type.downcase
    when 'clear'
      'precipitation'
    when 'mixed'
      'wintry mix'
    else
      type.downcase
    end
  end

  def format_air_quality(label)
    label.gsub('very', '_very_').gsub('hazardous', '**hazardous**')
  end

  def is_bad_weather?
    aqi = data.purple_air.aqi.value
    current_temperature = (data.weather.currentWeather.temperatureApparent || data.weather.currentWeather.temperature)
    high_temperature = data.weather.forecastDaily.days.first.temperatureMax
    low_temperature = data.weather.forecastDaily.days.first.temperatureMin
    precipitation_chance = data.weather.forecastDaily.days.first.restOfDayForecast.precipitationChance
    snowfall = data.weather.forecastDaily.days.first.restOfDayForecast.snowfallAmount

    return true if aqi > 75
    return true if current_temperature <= -12 || current_temperature >= 32
    return true if low_temperature <= -12 || high_temperature >= 32
    return true if precipitation_chance >= 0.5
    return true if snowfall > 0
    return !data.conditions.dig(data.weather.currentWeather.conditionCode, :safe)
    return !data.conditions.dig(data.weather.forecastDaily.days.first.conditionCode, :safe)
  end

  def is_good_weather?
    !is_bad_weather?
  end

  def is_hot?
    data.weather.currentWeather.temperature >= 32 || data.weather.currentWeather.temperatureApparent >= 32
  end

  def weather_summary
    summary = []
    summary << current_weather
    summary << current_aqi
    summary << forecast
    summary << activities
    markdown_to_html(summary.join(' '))
  end

  def current_weather
    return if data.weather.currentWeather.blank?
    current = []
    current << "It's race day!" if is_race_day?
    current << "Man, it's a hot one!" if !is_race_day? && is_hot?
    current << "I'm currently in **#{format_location}**, where"
    current << "#{format_current_condition(data.weather.currentWeather.conditionCode).downcase}, with a temperature of #{format_temperature(data.weather.currentWeather.temperature)}"
    current << ", which feels like #{format_temperature(data.weather.currentWeather.temperatureApparent)}" if data.weather.currentWeather.temperature.round != data.weather.currentWeather.temperatureApparent.round
    current << "."
    current.join(' ').gsub(/,\s*\./, '.').gsub(/\s+([,.])/, '\1').gsub(/\.+/, '.')
  end

  def current_aqi
    return if data.purple_air.aqi.value.blank?
    "The air quality is #{format_air_quality(data.purple_air.aqi.label.downcase)}, with an <abbr title=\"Air Quality Index\">AQI</abbr> of #{data.purple_air.aqi.value.round}."
  end

  def forecast
    return if data.weather.forecastDaily.blank?
    day = data.weather.forecastDaily.days.first
    forecast = []
    forecast << "#{today_or_tonight}'s forecast calls for #{format_forecasted_condition(day.restOfDayForecast.conditionCode).downcase},"
    forecast << "with a high of #{format_temperature(day.temperatureMax)} and a low of #{format_temperature(day.temperatureMin)}."
    forecast << "There's a #{number_to_percentage(day.restOfDayForecast.precipitationChance * 100, precision: 0)} chance of #{format_precipitation_type(day.restOfDayForecast.precipitationType)} later #{today_or_tonight.downcase}," if day.restOfDayForecast.precipitationChance > 0 && day.restOfDayForecast.precipitationType.downcase != 'clear'
    forecast << "with #{format_precipitation_amount(day.restOfDayForecast.snowfallAmount)} of snow expected" if day.restOfDayForecast.snowfallAmount > 0
    forecast << "."

    forecast.join(' ').gsub(/,\s*\./, '.').gsub(/\s+([,.])/, '\1').gsub(/\.+/, '.')
  end

  def activities
    activities = []
    if is_race_day?
      if is_good_weather?
        activities << "Good weather for racing!"
      else
        activities << "Tough weather for racing!"
      end
    else
      if is_good_weather?
        activities << "It's a good day for a bike ride!" if is_bike_scheduled?
        activities << "It's a good day to go for a run!" if is_run_scheduled?
        activities << "It's a good day to go swimming!" if is_swim_scheduled?
        activities << "It's a good day to spend time outside!" if !is_workout_scheduled?
      else
        activities << "It's a good day to ride indoors!" if is_bike_scheduled?
        activities << "It's a good day to hit the treadmill!" if is_run_scheduled?
        activities << "It's a good day to hit the pool!" if is_swim_scheduled?
        activities << "It's a good day to rest!" if !is_workout_scheduled?
      end
    end
    is_daytime? ? activities.sample : ''
  end

  def weather_icon
    condition = data.conditions[data.weather.currentWeather.conditionCode]
    return 'cloud-question' if condition.blank?
    if is_daytime?
      condition[:icon_day] || condition[:icon]
    else
      condition[:icon_night] || condition[:icon]
    end
  end
end
