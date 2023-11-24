module WeatherHelpers
  PRECIPITATION_METRIC_UNITS = {
    unit: 'mm',
    ten: 'cm',
    thousand: 'm'
  }

  def mm_to_in(mm)
    mm / 25.4
  end

  def todays_forecast
    now = Time.now
    data.weather.forecastDaily.days.find { |d| Time.parse(d.forecastStart) <= now && Time.parse(d.forecastEnd) >= now }
  end

  def tomorrows_forecast
    now = Time.now
    data.weather.forecastDaily.days.find { |d| Time.parse(d.forecastStart) > now }
  end

  def sunrise
    Time.parse(todays_forecast.sunrise).in_time_zone(data.time_zone.timeZoneId)
  end

  def tomorrows_sunrise
    Time.parse(tomorrows_forecast.sunrise).in_time_zone(data.time_zone.timeZoneId)
  end

  def sunset
    Time.parse(todays_forecast.sunset).in_time_zone(data.time_zone.timeZoneId)
  end

  def is_daytime?
    now = Time.now
    now >= sunrise.beginning_of_hour && now <= sunset.beginning_of_hour
  end

  def is_evening?
    Time.now >= sunset.beginning_of_hour
  end

  def today_or_tonight
    is_evening? ? "Tonight" : "Today"
  end

  def format_current_condition(condition_code)
    data.conditions.dig(condition_code, :labels, :current) || "It's #{condition_code.underscore.gsub('_', ' ')}"
  end

  def format_forecasted_condition(condition_code)
    data.conditions.dig(condition_code, :labels, :forecast) || "calls for #{condition_code.underscore.gsub('_', ' ')}"
  end

  def format_temperature(temp)
    celsius = "#{number_to_human(temp, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºC"
    fahrenheit = "#{number_to_human(celsius_to_fahrenheit(temp), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºF"
    content_tag :data, 'data-controller': 'units', 'data-units-imperial-value': fahrenheit, 'data-units-metric-value': celsius, title: "#{celsius} | #{fahrenheit}" do
      celsius
    end
  end

  def celsius_to_fahrenheit(celsius)
    (celsius * (9.0 / 5.0)) + 32
  end

  def format_precipitation_amount(mm)
    metric = if mm < 10
      "less than a centimeter"
    else
      number_to_human(mm, units: PRECIPITATION_METRIC_UNITS, precision: (mm > 1000 ? 1 : 0), strip_insignificant_zeros: true, significant: false, delimiter: ',')
    end

    inches = mm_to_in(mm)
    imperial = if inches < 1
      "less than an inch"
    else
      human_inches = number_to_human(inches, precision: (inches < 1 ? 1 : 0 ), strip_insignificant_zeros: true, significant: false, delimiter: ',')
      human_inches == "1" ? "#{human_inches} inch" : "#{human_inches} inches"
    end

    content_tag :data, 'data-controller': 'units', 'data-units-imperial-value': imperial, 'data-units-metric-value': metric, title: "#{metric} | #{imperial}" do
      metric
    end
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
    return true if low_temperature <= -12
    return true if high_temperature <= 0 || high_temperature >= 32
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

  def hide_apparent_temperature?
    celsius_temp = data.weather.currentWeather.temperature.round
    celsius_apparent = data.weather.currentWeather.temperatureApparent.round
    fahrenheit_temp = celsius_to_fahrenheit(data.weather.currentWeather.temperature).round
    fahrenheit_apparent = celsius_to_fahrenheit(data.weather.currentWeather.temperatureApparent).round
    celsius_temp == celsius_apparent || fahrenheit_temp == fahrenheit_apparent
  end

  def weather_summary
    return if current_weather.blank? && forecast.blank?
    summary = []
    summary << race_day
    summary << current_location
    summary << smooth
    summary << current_weather
    summary << current_aqi
    summary << forecast
    summary << precipitation
    summary << sunrise_or_sunset
    summary << activities
    markdown_to_html(summary.reject(&:blank?).map { |t| "<span>#{remove_widows(t)}</span>" }.join(' '))
  end

  def race_day
    "**It's race day!**" if is_race_day? && !is_evening?
  end

  def current_location
    "I'm currently in **#{format_location}**"
  end

  def smooth
    "Man, it's a hot one!" if !is_race_day? && is_hot?
  end

  def current_weather
    return if data.weather.currentWeather.blank?
    text = []
    text << "#{format_current_condition(data.weather.currentWeather.conditionCode)}, with a temperature of #{format_temperature(data.weather.currentWeather.temperature)}"
    text << "which feels like #{format_temperature(data.weather.currentWeather.temperatureApparent)}" unless hide_apparent_temperature?
    text.join(', ')
  end

  def current_aqi
    return if data.purple_air&.aqi&.value.blank?
    "The air quality is #{format_air_quality(data.purple_air&.aqi&.label.downcase)}, with an <abbr title=\"Air Quality Index\">AQI</abbr> of #{data.purple_air&.aqi&.value.round}"
  end

  def forecast
    return if todays_forecast.blank?
    text = []
    text << "#{today_or_tonight}'s forecast #{format_forecasted_condition(todays_forecast.restOfDayForecast.conditionCode).downcase}"
    if is_evening?
      text << "with a low of #{format_temperature(todays_forecast.temperatureMin)}"
    else
      text << "with a high of #{format_temperature(todays_forecast.temperatureMax)} and a low of #{format_temperature(todays_forecast.temperatureMin)}"
    end
    text.join(', ')
  end

  def precipitation
    return if todays_forecast.restOfDayForecast.precipitationChance == 0 || todays_forecast.restOfDayForecast.precipitationType.downcase == 'clear'
    percentage_string = number_to_percentage(todays_forecast.restOfDayForecast.precipitationChance * 100, precision: 0)
    article = ["8", "11", "18"].any? { |prefix| percentage_string.start_with?(prefix) } ? "an" : "a"
    text = []
    text << "There's #{article} #{percentage_string} chance of #{format_precipitation_type(todays_forecast.restOfDayForecast.precipitationType)} later #{today_or_tonight.downcase}"
    text << "with #{format_precipitation_amount(todays_forecast.restOfDayForecast.snowfallAmount)} expected" if todays_forecast.restOfDayForecast.precipitationType.downcase == 'snow' && todays_forecast.restOfDayForecast.snowfallAmount > 0
    text.join(', ')
  end

  def sunrise_or_sunset
    now = Time.now
    return "Sunrise will be at #{format_time(sunrise)}" if now <= sunrise.beginning_of_hour
    return "Sunset will be at #{format_time(sunset)}" if now >= sunrise.beginning_of_hour && now < sunset.beginning_of_hour
    return "Sunrise will be at #{format_time(tomorrows_sunrise)}" if now >= sunset.beginning_of_hour
  end

  def format_time(time)
    time.strftime('%l:%M %p').gsub(/(am|pm)/i, "<abbr>\\1</abbr>")
  end

  def activities
    return unless is_daytime?

    if is_race_day? && is_good_weather?
      return "Good weather for racing!"
    elsif is_race_day? && is_bad_weather?
      return "Tough weather for racing!"
    elsif no_workout_scheduled? && is_good_weather?
      return "It's a good day to be outside!"
    elsif no_workout_scheduled? && is_bad_weather?
      return "It's a good day to rest!"
    elsif is_good_weather?
      return "It's a good day to train outside!"
    elsif is_bad_weather?
      return "It's a good day to train indoors!"
    end
  end

  def weather_icon
    condition = data.conditions[data.weather.currentWeather.conditionCode]
    return 'cloud-question' if condition.blank?
    return condition[:icon] if condition[:icon].is_a?(String)
    is_daytime? ? condition[:icon][:day] : condition[:icon][:night]
  end
end
