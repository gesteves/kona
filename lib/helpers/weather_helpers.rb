require 'active_support/all'

module WeatherHelpers
  include ActiveSupport::NumberHelper
  PRECIPITATION_METRIC_UNITS = {
    unit: 'mm',
    ten: 'cm',
    thousand: 'm'
  }

  # Retrieves the forecast for the current day.
  # @return [Hash, nil] The forecast data for today, or nil if not found.
  def todays_forecast
    now = Time.now
    data.weather.forecastDaily.days.find { |d| Time.parse(d.forecastStart) <= now && Time.parse(d.forecastEnd) >= now }
  end

  # Retrieves the forecast for tomorrow.
  # @return [Hash, nil] The forecast data for tomorrow, or nil if not found.
  def tomorrows_forecast
    now = Time.now
    data.weather.forecastDaily.days.find { |d| Time.parse(d.forecastStart) > now }
  end

  # Retrieves the time of sunrise for today.
  # @return [Time, nil] The time of sunrise today, or nil if not found.
  def sunrise
    Time.parse(todays_forecast.sunrise).in_time_zone(data.time_zone.timeZoneId)
  end

  # Retrieves the time of sunrise for tomorrow.
  # @return [Time, nil] The time of sunrise tomorrow, or nil if not found.
  def tomorrows_sunrise
    Time.parse(tomorrows_forecast.sunrise).in_time_zone(data.time_zone.timeZoneId)
  end

  # Retrieves the time of sunset for today.
  # @return [Time, nil] The time of sunset today, or nil if not found.
  def sunset
    Time.parse(todays_forecast.sunset).in_time_zone(data.time_zone.timeZoneId)
  end

  # Checks if it is currently daytime (i.e. between sunrise and sunset).
  # @return [Boolean] true if it is daytime, false otherwise.
  def is_daytime?
    now = Time.now
    now >= sunrise.beginning_of_hour && now <= sunset.beginning_of_hour
  end

  # Checks if it is currently evening (i.e. after sunset).
  # @return [Boolean] true if it is evening, false otherwise.
  def is_evening?
    Time.now >= sunset.beginning_of_hour
  end

  # Determines whether to refer to the current time as "Today" or "Tonight"
  # based on the time of day (evening or not).
  # @return [String] "Today" if it's not evening, "Tonight" if it's evening.
  def today_or_tonight
    is_evening? ? "Tonight" : "Today"
  end

  # Formats the current weather condition based on its condition code.
  # @param [String] condition_code - The condition code representing the current weather.
  # @return [String] The formatted current weather condition description.
  def format_current_condition(condition_code)
    data.conditions.dig(condition_code, :labels, :current) || "It's #{condition_code.underscore.gsub('_', ' ')}"
  end

  # Formats the forecasted weather condition based on its condition code.
  # @param [String] condition_code - The condition code representing the forecasted weather.
  # @return [String] The formatted forecasted weather condition description.
  def format_forecasted_condition(condition_code)
    data.conditions.dig(condition_code, :labels, :forecast) || "calls for #{condition_code.underscore.gsub('_', ' ')}"
  end

  # Formats a temperature value in Celsius to both Celsius and Fahrenheit.
  # @param [Float] temp - The temperature value in Celsius.
  # @return [String] A formatted temperature value with units in both Celsius and Fahrenheit.
  def format_temperature(temp)
    celsius = "#{number_to_human(temp, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºC"
    fahrenheit = "#{number_to_human(celsius_to_fahrenheit(temp), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºF"
    content_tag :data, 'data-controller': 'units', 'data-units-imperial-value': fahrenheit, 'data-units-metric-value': celsius do
      celsius
    end
  end

  # Formats a precipitation amount from millimeters (mm) to both metric and imperial units.
  # @param [Float] mm - The precipitation amount in millimeters (mm).
  # @return [String] A formatted string representing the precipitation amount in both metric and imperial units.
  def format_precipitation_amount(mm)
    metric = if mm < 10
      "less than a centimeter"
    else
      number_to_human(mm, units: PRECIPITATION_METRIC_UNITS, precision: (mm > 1000 ? 1 : 0), strip_insignificant_zeros: true, significant: false, delimiter: ',')
    end

    inches = millimeters_to_inches(mm)
    imperial = if inches < 1
      "less than an inch"
    else
      human_inches = number_to_human(inches, precision: (inches < 1 ? 1 : 0 ), strip_insignificant_zeros: true, significant: false, delimiter: ',')
      human_inches == "1" ? "#{human_inches} inch" : "#{human_inches} inches"
    end

    content_tag :data, 'data-controller': 'units', 'data-units-imperial-value': imperial, 'data-units-metric-value': metric do
      metric
    end
  end

  # Formats a precipitation type for display.
  # @param [String] type - The precipitation type (e.g., 'clear', 'mixed').
  # @return [String] A formatted string representing the precipitation type.
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

  # Adds formatting to add emphasis to bad AQI values.
  # @param [String] The AQI description.
  # @return [String] A formatted string representing the AQI.
  def format_air_quality(label)
    label.gsub('very', '_very_').gsub('hazardous', '**hazardous**')
  end

  # Determines if the current weather conditions are considered "bad".
  # @return [Boolean] `true` if the weather conditions are bad, `false` otherwise.
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

  # Determines if the current weather conditions are considered "good".
  # @return [Boolean] `true` if the weather conditions are good, `false` otherwise.
  def is_good_weather?
    !is_bad_weather?
  end

  # Determines if the current temperature is hot.
  # @return [Boolean] `true` if the temperature is hot (32°C or higher), `false` otherwise.
  def is_hot?
    data.weather.currentWeather.temperature >= 32 || data.weather.currentWeather.temperatureApparent >= 32
  end

  # Determines if the apparent temperature should be hidden.
  # @return [Boolean] `true` if the apparent temperature should be hidden, `false` otherwise.
  def hide_apparent_temperature?
    celsius_temp = data.weather.currentWeather.temperature.round
    celsius_apparent = data.weather.currentWeather.temperatureApparent.round
    fahrenheit_temp = celsius_to_fahrenheit(data.weather.currentWeather.temperature).round
    fahrenheit_apparent = celsius_to_fahrenheit(data.weather.currentWeather.temperatureApparent).round
    celsius_temp == celsius_apparent || fahrenheit_temp == fahrenheit_apparent
  end

  # Generates a summary of weather-related information.
  # @return [String] An HTML-formatted summary of weather-related information.
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
    markdown_to_html(summary.reject(&:blank?).map { |t| "<span>#{t}</span>" }.join(' '))
  end

  # Generates a race-day preamble.
  # @return [String, nil] A Markdown-formatted message indicating race day, or `nil` if it's not race day or it's evening.
  def race_day
    "**It's race day!**" if is_race_day? && !is_evening?
  end

  # Formats my current location.
  # @return [String] A Markdown-formatted string indicating my current location.
  def current_location
    "I'm currently in **#{format_location}**"
  end

  # Determines if it's a hot one.
  # @return [String, nil] The first lyric from the Grammy-award winning 1999 hit SMOOTH by Santana featuring Rob Thomas of Matchbox Twenty off the multi-platinum album Supernatural.
  def smooth
    "Man, it's a hot one!" if !is_race_day? && is_hot?
  end

  # Provides a summary of current weather conditions.
  # @return [String, nil] A string describing the current weather conditions or nil if no data is available.
  def current_weather
    return if data.weather.currentWeather.blank?
    text = []
    text << "#{format_current_condition(data.weather.currentWeather.conditionCode)}, with a temperature of #{format_temperature(data.weather.currentWeather.temperature)}"
    text << "which feels like #{format_temperature(data.weather.currentWeather.temperatureApparent)}" unless hide_apparent_temperature?
    text.join(', ')
  end

  # Provides a summary of the current Air Quality Index (AQI).
  # @return [String, nil] A string describing the current AQI or nil if no data is available.
  def current_aqi
    return if data.purple_air&.aqi&.value.blank?
    "The air quality is #{format_air_quality(data.purple_air&.aqi&.label.downcase)}, with an <abbr title=\"Air Quality Index\">AQI</abbr> of #{data.purple_air&.aqi&.value.round}"
  end

  # Provides the weather forecast for today or tonight.
  # @return [String, nil] A string describing the weather forecast for today or tonight, or nil if no data is available.
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

  # Provides a summary of precipitation for today or tonight.
  # @return [String, nil] A string describing the precipitation details for today or tonight, or nil if no data is available.
  def precipitation
    return if todays_forecast.restOfDayForecast.precipitationChance == 0 || todays_forecast.restOfDayForecast.precipitationType.downcase == 'clear'
    percentage_string = number_to_percentage(todays_forecast.restOfDayForecast.precipitationChance * 100, precision: 0)
    text = []
    text << "There's #{with_indefinite_article(percentage_string)} chance of #{format_precipitation_type(todays_forecast.restOfDayForecast.precipitationType)} later #{today_or_tonight.downcase}"
    text << "with #{format_precipitation_amount(todays_forecast.restOfDayForecast.snowfallAmount)} expected" if todays_forecast.restOfDayForecast.precipitationType.downcase == 'snow' && todays_forecast.restOfDayForecast.snowfallAmount > 0
    text.join(', ')
  end

  # Determines and formats the next sunrise or sunset time.
  # @return [String] A string indicating whether the next event is a sunrise or sunset and the formatted time of that event.
  def sunrise_or_sunset
    now = Time.now
    return "Sunrise will be at #{format_time(sunrise)}" if now <= sunrise.beginning_of_hour
    return "Sunset will be at #{format_time(sunset)}" if now >= sunrise.beginning_of_hour && now < sunset.beginning_of_hour
    return "Sunrise will be at #{format_time(tomorrows_sunrise)}" if now >= sunset.beginning_of_hour
  end

  # Formats a time object as a human-readable string with an abbreviation for AM/PM.
  # @param time [Time] The `Time` object to be formatted.
  # @return [String] The formatted time string with AM or PM abbreviation.
  def format_time(time)
    time.strftime('%l:%M %p').gsub(/(am|pm)/i, "<abbr>\\1</abbr>")
  end

  # Generates a recommendation for activities based on current conditions and schedules.
  # @return [String, nil] A recommendation for activities, or nil if no recommendation is available.
  def activities
    return unless is_daytime?

    if is_race_day?
      if is_good_weather?
        return "Good weather for racing!"
      else
        return "Tough weather for racing!"
      end
    end

    if is_indoor_season?
      if is_workout_scheduled?
        return "It's a good day to train indoors!"
      else
        return "It's a good day to rest!"
      end
    end

    if is_workout_scheduled?
      if is_good_weather?
        return "It's a good day to train outside!"
      else
        return "It's a good day to train indoors!"
      end
    end

    if is_good_weather?
      return "It's a good day to be outside!"
    else
      return "It's a good day to rest!"
    end
  end

  # Determines the weather icon to display based on current weather conditions.
  # @return [String] The name of the weather icon to display.
  def weather_icon
    condition = data.conditions[data.weather.currentWeather.conditionCode]
    return 'cloud-question' if condition.blank?
    return condition[:icon] if condition[:icon].is_a?(String)
    is_daytime? ? condition[:icon][:day] : condition[:icon][:night]
  end
end
