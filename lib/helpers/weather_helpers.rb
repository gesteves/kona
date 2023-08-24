module WeatherHelpers
  PRECIPITATION_METRIC_UNITS = {
    unit: 'mm',
    ten: 'cm',
    thousand: 'm'
  }

  PRECIPITATION_IMPERIAL_UNITS = {
    unit: 'in'
  }

  def mm_to_in(mm)
    mm / 25.4
  end

  def todays_forecast
    now = Time.now
    data.weather.forecastDaily.days.find { |d| Time.parse(d.forecastStart) <= now && Time.parse(d.forecastEnd) >= now }
  end

  def is_daytime?
    now = Time.now
    sunrise = Time.parse(todays_forecast.sunrise)
    sunset = Time.parse(todays_forecast.sunset)
    now > sunrise && now < sunset
  rescue
    true
  end

  def is_evening?
    now = Time.now
    sunset = Time.parse(todays_forecast.sunset)
    now > sunset
  end

  def today_or_tonight
    is_evening? ? "Tonight" : "Today"
  end

  def format_current_condition(condition_code)
    data.conditions.dig(condition_code, :labels, :current) || "it's #{condition_code.underscore.gsub('_', ' ')}"
  end

  def format_forecasted_condition(condition_code)
    data.conditions.dig(condition_code, :labels, :forecast) || "calls for #{condition_code.underscore.gsub('_', ' ')}"
  end

  def format_temperature(temp)
    celsius = "#{number_to_human(temp, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºC"
    fahrenheit = "#{number_to_human(celsius_to_fahrenheit(temp), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºF"
    "<data title=\"#{fahrenheit}\">#{celsius}</data>"
  end

  def celsius_to_fahrenheit(celsius)
    (celsius * (9.0 / 5.0)) + 32
  end

  def format_precipitation_amount(mm)
    metric = number_to_human(mm, units: PRECIPITATION_METRIC_UNITS, precision: (mm > 1000 ? 1 : 0), strip_insignificant_zeros: true, significant: false, delimiter: ',')
    imperial = number_to_human(mm_to_in(mm), units: PRECIPITATION_IMPERIAL_UNITS, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')
    "<data title=\"#{imperial}\">#{metric}</data>"
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
    aqi = data&.purple_air&.aqi&.value.to_i
    current_temperature = (data.weather.currentWeather.temperatureApparent || data.weather.currentWeather.temperature)
    high_temperature = todays_forecast.temperatureMax
    low_temperature = todays_forecast.temperatureMin
    precipitation_chance = todays_forecast.restOfDayForecast.precipitationChance
    snowfall = todays_forecast.restOfDayForecast.snowfallAmount

    return true if aqi > 75
    return true if current_temperature <= -12 || current_temperature >= 32
    return true if low_temperature <= -12 || high_temperature >= 32
    return true if precipitation_chance >= 0.5
    return true if snowfall > 0
    return !data.conditions.dig(data.weather.currentWeather.conditionCode, :is_good_weather)
    return !data.conditions.dig(todays_forecast.conditionCode, :is_good_weather)
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
    markdown_to_html(clean_up_punctuation(summary.join(' ')))
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
    return "It's race day!" if is_race_day? && !is_evening?
    return "Man, it's a hot one!" if !is_race_day? && is_hot?
  end

  def current_weather
    return if data.weather.currentWeather.blank?
    current = []
    current << "I'm currently in **#{format_location}**, where"
    current << "#{format_current_condition(data.weather.currentWeather.conditionCode).downcase}, with a temperature of #{format_temperature(data.weather.currentWeather.temperature)}"
    current << ", which feels like #{format_temperature(data.weather.currentWeather.temperatureApparent)}" if data.weather.currentWeather.temperature.round != data.weather.currentWeather.temperatureApparent.round
    current << "."
    current.join(' ')
  end

  def current_aqi
    return if data.purple_air&.aqi&.value.blank?
    "The air quality is #{format_air_quality(data.purple_air&.aqi&.label.downcase)}, with an <abbr title=\"Air Quality Index\">AQI</abbr> of #{data.purple_air&.aqi&.value.round}."
  end

  def forecast
    return if todays_forecast.blank?
    day = todays_forecast
    forecast = []
    forecast << "#{today_or_tonight}'s forecast #{format_forecasted_condition(day.restOfDayForecast.conditionCode).downcase},"
    forecast << "with a high of #{format_temperature(day.temperatureMax)} and a low of #{format_temperature(day.temperatureMin)}."
    forecast << "There's a #{number_to_percentage(day.restOfDayForecast.precipitationChance * 100, precision: 0)} chance of #{format_precipitation_type(day.restOfDayForecast.precipitationType)} later #{today_or_tonight.downcase}," if day.restOfDayForecast.precipitationChance > 0 && day.restOfDayForecast.precipitationType.downcase != 'clear'
    forecast << "with #{format_precipitation_amount(day.restOfDayForecast.snowfallAmount)} of snow expected" if day.restOfDayForecast.snowfallAmount > 0
    forecast << "."

    forecast.join(' ')
  end

  def activities
    return if is_evening?

    if is_race_day? && is_good_weather?
      return "Good weather for racing!"
    elsif is_race_day? && is_bad_weather?
      return "Tough weather for racing!"
    elsif no_workout_scheduled? && is_good_weather?
      return "I don't have any workouts scheduled for today, but it's a good day to be outside."
    elsif no_workout_scheduled? && is_bad_weather?
      return "I don't have any workouts scheduled for today so it's a good day to rest."
    end

    workouts = data.trainerroad.workouts.map { |w| workout_with_article(w) }

    activities = ["My training plan has"]
    activities << comma_join_with_and(workouts)
    activities << if is_good_weather?
      "scheduled for today—and it's a good day to train outside."
    else
      "scheduled for today—so it's a good day to train indoors."
    end

    activities.join(' ')
  end

  def weather_icon
    condition = data.conditions[data.weather.currentWeather.conditionCode]
    return 'cloud-question' if condition.blank?
    return condition[:icon] if condition[:icon].is_a?(String)
    is_daytime? ? condition[:icon][:day] : condition[:icon][:night]
  end
end
