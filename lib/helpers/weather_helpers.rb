module WeatherHelpers
  PRECIPITATION_UNITS = {
    unit: 'mm',
    ten: 'cm',
    thousand: 'm'
  }

  def format_temperature(temp)
    celsius = "#{number_to_human(temp, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºC"
    fahrenheit = "#{number_to_human(celsius_to_fahrenheit(temp), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºF"
    "<data title=\"#{fahrenheit}\">#{celsius}</data>"
  end

  def celsius_to_fahrenheit(temp)
    temp * 9.0 / 5.0 + 32
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

  def format_current_condition(condition_code)
    data.conditions.dig(condition_code, :labels, :current) || "it's #{condition_code.underscore.gsub('_', ' ')}"
  end

  def format_forecasted_condition(condition_code)
    data.conditions.dig(condition_code, :labels, :forecast) || "calls for #{condition_code.underscore.gsub('_', ' ')}"
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
    return !data.conditions.dig(data.weather.currentWeather.conditionCode, :is_good_weather)
    return !data.conditions.dig(data.weather.forecastDaily.days.first.conditionCode, :is_good_weather)
  end

  def is_good_weather?
    !is_bad_weather?
  end

  def is_hot?
    data.weather.currentWeather.temperature >= 32 || data.weather.currentWeather.temperatureApparent >= 32
  end

  def weather_summary
    return if current_weather.blank? && forecast.blank?
    summary = []
    summary << intro
    summary << current_weather
    summary << current_aqi
    summary << forecast
    summary << activities
    markdown_to_html(remove_widows(clean_up_punctuation(summary.join(' '))))
  end

  def clean_up_punctuation(s)
    # Remove whitespace before any commas or periods
    s.gsub!(/\s+([,.—])/, '\1')

    # Replace multiple commas or periods with a single one
    s.gsub!(/,+/ , ',')
    s.gsub!(/\.\.+/ , '.')

    # Replace a comma and a period next to each other with a period
    s.gsub!(/,\.|\.,/ , '.')

    s
  end

  def intro
    return unless is_daytime?
    return "It's race day!" if is_race_day?
    return "Man, it's a hot one!" if !is_race_day? && is_hot?
  end

  def current_weather
    return if data.weather&.currentWeather.blank?
    current = []
    current << "I'm currently in **#{format_location}**, where"
    current << "#{format_current_condition(data.weather.currentWeather.conditionCode).downcase}, with a temperature of #{format_temperature(data.weather.currentWeather.temperature)}"
    current << ", which feels like #{format_temperature(data.weather.currentWeather.temperatureApparent)}" if data.weather.currentWeather.temperature.round != data.weather.currentWeather.temperatureApparent.round
    current << "."
    current.join(' ')
  end

  def current_aqi
    return if data.purple_air&.aqi&.value.blank?
    "The air quality is #{format_air_quality(data.purple_air.aqi.label.downcase)}, with an <abbr title=\"Air Quality Index\">AQI</abbr> of #{data.purple_air.aqi.value.round}."
  end

  def forecast
    return if data.weather&.forecastDaily&.days&.first.blank?
    day = data.weather.forecastDaily.days.first
    forecast = []
    forecast << "#{today_or_tonight}'s forecast #{format_forecasted_condition(day.restOfDayForecast.conditionCode).downcase},"
    forecast << "with a high of #{format_temperature(day.temperatureMax)} and a low of #{format_temperature(day.temperatureMin)}."
    forecast << "There's a #{number_to_percentage(day.restOfDayForecast.precipitationChance * 100, precision: 0)} chance of #{format_precipitation_type(day.restOfDayForecast.precipitationType)} later #{today_or_tonight.downcase}," if day.restOfDayForecast.precipitationChance > 0 && day.restOfDayForecast.precipitationType.downcase != 'clear'
    forecast << "with #{format_precipitation_amount(day.restOfDayForecast.snowfallAmount)} of snow expected" if day.restOfDayForecast.snowfallAmount > 0
    forecast << "."

    forecast.join(' ')
  end

  def activities
    return unless is_daytime?
    activities = []

    if is_race_day? && is_good_weather?
      return "Good weather for racing!"
    elsif is_race_day? && is_bad_weather?
      return "Tough weather for racing!"
    elsif !is_workout_scheduled? && is_good_weather?
      return "I don't have any workouts scheduled for today, but it's a good day to be outside!"
    elsif !is_workout_scheduled? && is_bad_weather?
      return "I don't have any workouts scheduled for today so it's a good day to rest!"
    end

    workouts = data.trainerroad.workouts.uniq(&:discipline).map { |w| "a #{w.description}"}

    activities << "My training plan has"
    activities << (workouts.size <= 2 ? workouts.join(' and ') : [workouts[0..-2].join(', '), workouts[-1]].join(' and '))
    activities << if is_good_weather?
      "scheduled for today—it's a good day to train outside!"
    else
      "scheduled for today—it's a good day to train indoors!"
    end

    activities.join(' ')
  end

  def weather_icon
    condition = data.conditions[data.weather.currentWeather.conditionCode]
    return 'cloud-question' if condition.blank?
    if is_daytime?
      condition[:icon][:day] || condition[:icon]
    else
      condition[:icon][:night] || condition[:icon]
    end
  end
end
