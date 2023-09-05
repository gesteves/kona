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
    now >= sunrise && now <= sunset
  rescue
    true
  end

  def is_evening?
    Time.now >= sunset
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
    metric = number_to_human(mm, units: PRECIPITATION_METRIC_UNITS, precision: (mm > 1000 ? 1 : 0), strip_insignificant_zeros: true, significant: false, delimiter: ',')
    imperial = number_to_human(mm_to_in(mm), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')
    imperial += (imperial == "1" ? " inch" : " inches")
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
    summary << current_location
    summary << current_weather
    summary << current_aqi
    summary << forecast
    summary << precipitation
    summary << sunrise_or_sunset
    summary << activities
    markdown_to_html(summary.reject(&:blank?).map { |t| "<span>#{t}</span>" }.join(' '))
  end

  def intro
    return "**It's race day!**" if is_race_day? && !is_evening?
    return "Man, it's a hot one!" if !is_race_day? && is_hot?
  end

  def current_location
    "I'm currently in **#{format_location}**"
  end

  def current_weather
    return if data.weather.currentWeather.blank?
    text = []
    text << "#{format_current_condition(data.weather.currentWeather.conditionCode)}, with a temperature of #{format_temperature(data.weather.currentWeather.temperature)}"
    text << "which feels like #{format_temperature(data.weather.currentWeather.temperatureApparent)}" if data.weather.currentWeather.temperature.round != data.weather.currentWeather.temperatureApparent.round
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
    text << "with a high of #{format_temperature(todays_forecast.temperatureMax)} and a low of #{format_temperature(todays_forecast.temperatureMin)}"
    text.join(', ')
  end

  def precipitation
    return if todays_forecast.restOfDayForecast.precipitationChance == 0 || todays_forecast.restOfDayForecast.precipitationType.downcase == 'clear'
    text = []
    text << "There's a #{number_to_percentage(todays_forecast.restOfDayForecast.precipitationChance * 100, precision: 0)} chance of #{format_precipitation_type(todays_forecast.restOfDayForecast.precipitationType)} later #{today_or_tonight.downcase}"
    text << "with #{format_precipitation_amount(todays_forecast.restOfDayForecast.snowfallAmount)} expected" if todays_forecast.restOfDayForecast.precipitationType.downcase == 'snow' && todays_forecast.restOfDayForecast.snowfallAmount > 0
    text.join(', ')
  end

  def sunrise_or_sunset
    now = Time.now
    return "Sunrise will be at #{sunrise.strftime('%I:%M %p').gsub(/(am|pm)/i, "<abbr>\\1</abbr>")}" if now <= sunrise
    return "Sunset will be at #{sunset.strftime('%I:%M %p').gsub(/(am|pm)/i, "<abbr>\\1</abbr>")}" if now >= sunrise && now < sunset
    return "Sunrise will be at #{tomorrows_sunrise.strftime('%I:%M %p').gsub(/(am|pm)/i, "<abbr>\\1</abbr>")}" if now >= sunset
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
