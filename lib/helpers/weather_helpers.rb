require 'active_support/all'

module WeatherHelpers
  include ActiveSupport::NumberHelper
  PRECIPITATION_METRIC_UNITS = {
    unit: 'mm',
    ten: 'cm',
    thousand: 'm'
  }

  # Retrieves the current weather conditions.
  # @return [Hash, nil] The current weather conditions data, or nil if not found.
  def current_weather
    data.weather.current_weather
  end

  # Retrieves the forecast for the current day.
  # @return [Hash, nil] The forecast data for today, or nil if not found.
  def todays_forecast
    now = Time.now
    data.weather.forecast_daily&.days&.find { |d| Time.parse(d.forecast_start) <= now && Time.parse(d.forecast_end) >= now }
  end

  # Retrieves the forecast for tomorrow.
  # @return [Hash, nil] The forecast data for tomorrow, or nil if not found.
  def tomorrows_forecast
    now = Time.now
    data.weather.forecast_daily.days.find { |d| Time.parse(d.forecast_start) > now }
  end

  # Retrieves the time of sunrise for today.
  # @return [Time, nil] The time of sunrise today, or nil if not found.
  def sunrise
    Time.parse(todays_forecast.sunrise).in_time_zone(location_time_zone)
  end

  # Retrieves the time of sunrise for tomorrow.
  # @return [Time, nil] The time of sunrise tomorrow, or nil if not found.
  def tomorrows_sunrise
    Time.parse(tomorrows_forecast.sunrise).in_time_zone(location_time_zone)
  end

  # Retrieves the time of sunset for today.
  # @return [Time, nil] The time of sunset today, or nil if not found.
  def sunset
    Time.parse(todays_forecast.sunset).in_time_zone(location_time_zone)
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
    data.conditions.dig(condition_code, :phrases, :currently) || "it's #{condition_code.underscore.gsub('_', ' ')}"
  end

  # Formats the forecasted weather condition based on its condition code.
  # @param [String] condition_code - The condition code representing the forecasted weather.
  # @return [String] The formatted forecasted weather condition description.
  def format_forecasted_condition(condition_code)
    data.conditions.dig(condition_code, :phrases, :forecast) || "calls for #{condition_code.underscore.gsub('_', ' ')}"
  end

  # Formats a temperature value in Celsius to both Celsius and Fahrenheit.
  # @param [Float] temp - The temperature value in Celsius.
  # @return [String] A formatted temperature value with units in both Celsius and Fahrenheit.
  def format_temperature(temp)
    celsius = "#{number_to_human(temp, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºC"
    fahrenheit = "#{number_to_human(celsius_to_fahrenheit(temp), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}ºF"
    units_tag(celsius, fahrenheit)
  end

  # Formats a precipitation amount from millimeters (mm) to both metric and imperial units.
  # @param [Float] mm - The precipitation amount in millimeters (mm).
  # @return [String] A formatted string representing the precipitation amount in both metric and imperial units.
  def format_precipitation_amount(mm)
    metric = if mm < 10
      "less than a centimeter"
    else
      amount = number_to_human(mm, units: PRECIPITATION_METRIC_UNITS, precision: (mm > 1000 ? 1 : 0), strip_insignificant_zeros: true, significant: false, delimiter: ',')
      "about #{amount}"
    end

    inches = millimeters_to_inches(mm)
    imperial = if inches < 1
      "less than an inch"
    else
      human_inches = number_to_human(inches, precision: (inches < 1 ? 1 : 0 ), strip_insignificant_zeros: true, significant: false, delimiter: ',')
      amount = human_inches == "1" ? "#{human_inches} inch" : "#{human_inches} inches"
      "about #{amount}"
    end

    units_tag(metric, imperial)
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

  # Returns a hash with the highest pollen level.
  # @see https://developers.google.com/maps/documentation/pollen/reference/rest/v1/forecast/lookup#indexinfo
  # @return [Hash, nil]
  def highest_pollen_level
    data.pollen&.pollen_type_info&.filter { |p| p&.index_info&.value.to_i > 0 }&.max_by { |p| p.index_info.value }
  end

  # Returns the pollen index, from 0 to 5.
  # @see https://developers.google.com/maps/documentation/pollen/reference/rest/v1/forecast/lookup#indexinfo
  # @return [Integer] The pollen index, where 0 is "none", and 5 is "very high"
  def pollen_index
    highest_pollen_level&.index_info&.value.to_i
  end

  # Returns the pollen level's description.
  # @return [String, nil] Description of the highest pollen level or nil.
  def current_pollen
    return if pollen_index.zero?
    "Pollen levels are #{highest_level.index_info.category.downcase}"
  end

  # Determines if the current weather conditions are considered "bad" for working out outdoors.
  # @return [Boolean] `true` if the weather conditions are bad, `false` otherwise.
  def is_bad_weather?
    aqi = data&.air_quality&.aqi.to_i
    current_temperature = (current_weather.temperature_apparent || current_weather.temperature)
    high_temperature = todays_forecast.temperature_max
    low_temperature = todays_forecast.temperature_min
    precipitation_chance = todays_forecast.rest_of_day_forecast.precipitation_chance
    snowfall = todays_forecast.rest_of_day_forecast.snowfall_amount

    # Air quality is moderate or worse
    return true if aqi > 75
    # Current temp is too cold or too hot
    return true if current_temperature <= -12 || current_temperature >= 35
    # Forecasted low temp is too cold
    return true if low_temperature <= -12
    # Forecasted high temp is too cold or too hot
    return true if high_temperature <= 0 || high_temperature >= 35
    # It's likely to rain
    return true if precipitation_chance >= 0.5
    # There's gonna be accumulating snow
    return true if snowfall > 0
    # Pollen is high or very high
    return true if pollen_index >= 4
    # The current or forecasted conditions are adverse weather
    data.conditions.dig(current_weather.condition_code, :adverse_weather) || data.conditions.dig(todays_forecast.condition_code, :adverse_weather)
  end

  # Determines if the current weather conditions are considered "good" for working out outdoors..
  # @return [Boolean] `true` if the weather conditions are good, `false` otherwise.
  def is_good_weather?
    !is_bad_weather?
  end

  # Determines if the current temperature is hot.
  # @return [Boolean] `true` if the temperature is hot, `false` otherwise.
  def is_hot?
    current_weather.temperature >= 30 || current_weather.temperature_apparent >= 30
  end

  # Determines if the apparent temperature should be hidden.
  # @return [Boolean] `true` if the apparent temperature should be hidden, `false` otherwise.
  def hide_apparent_temperature?
    celsius_temp = current_weather.temperature.round
    celsius_apparent = current_weather.temperature_apparent.round
    fahrenheit_temp = celsius_to_fahrenheit(current_weather.temperature).round
    fahrenheit_apparent = celsius_to_fahrenheit(current_weather.temperature_apparent).round
    celsius_temp == celsius_apparent || fahrenheit_temp == fahrenheit_apparent
  end

  # Generates a summary of weather-related information.
  # @return [String] An HTML-formatted summary of weather-related information.
  def weather_summary
    return if currently.blank? && forecast.blank?
    summary = []
    summary << race_day
    summary << smooth
    summary << current_location
    summary << elevation
    summary << currently
    summary << current_aqi
    summary << current_pollen
    summary << forecast
    summary << precipitation
    summary << sunrise_or_sunset
    summary << remove_widows(activities)
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

  def elevation
    return if format_elevation.blank?
    "The elevation is #{format_elevation}"
  end

  # Determines if it's a hot one.
  # @return [String, nil] The opening words of the Grammy-award winning 1999 hit SMOOTH by Santana featuring Rob Thomas of Matchbox Twenty off the multi-platinum album Supernatural.
  def smooth
    "Man, it's a hot one!" if !is_race_day? && is_hot?
  end

  # Provides a summary of current weather conditions.
  # @return [String, nil] A string describing the current weather conditions or nil if no data is available.
  def currently
    return if current_weather.blank?
    text = []
    text << "#{format_current_condition(current_weather.condition_code).capitalize}, with a temperature of #{format_temperature(current_weather.temperature)}"
    text << "which feels like #{format_temperature(current_weather.temperature_apparent)}" unless hide_apparent_temperature?
    text.join(', ')
  end

  # Provides a summary of the current Air Quality Index (AQI).
  # @return [String, nil] A string describing the current AQI or nil if no data is available.
  def current_aqi
    return if data&.air_quality&.aqi.blank?
    "The air quality is #{format_air_quality(data.air_quality&.category&.downcase)}, with an <abbr title=\"Air Quality Index\">AQI</abbr> of #{data.air_quality&.aqi&.round}"
  end

  # Provides the weather forecast for today or tonight.
  # @return [String, nil] A string describing the weather forecast for today or tonight, or nil if no data is available.
  def forecast
    return if todays_forecast.blank?
    text = []
    text << "#{today_or_tonight}'s forecast #{format_forecasted_condition(todays_forecast.rest_of_day_forecast.condition_code).downcase}"
    if is_evening?
      text << "with a low of #{format_temperature(todays_forecast.temperature_min)}"
    else
      text << "with a high of #{format_temperature(todays_forecast.temperature_max)} and a low of #{format_temperature(todays_forecast.temperature_min)}"
    end
    text.join(', ')
  end

  # Provides a summary of precipitation for today or tonight.
  # @return [String, nil] A string describing the precipitation details for today or tonight, or nil if no data is available.
  def precipitation
    return if todays_forecast.rest_of_day_forecast.precipitation_chance == 0 || todays_forecast.rest_of_day_forecast.precipitation_type.downcase == 'clear'
    percentage_string = number_to_percentage(todays_forecast.rest_of_day_forecast.precipitation_chance * 100, precision: 0)
    text = []
    text << "There's #{with_indefinite_article(percentage_string)} chance of #{format_precipitation_type(todays_forecast.rest_of_day_forecast.precipitation_type)} later #{today_or_tonight.downcase}"
    text << "with #{format_precipitation_amount(todays_forecast.rest_of_day_forecast.snowfall_amount)} expected" if todays_forecast.rest_of_day_forecast.precipitation_type.downcase == 'snow' && todays_forecast.rest_of_day_forecast.snowfall_amount > 0
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
    remove_widows(time.strftime('%l:%M %p')).gsub(/(am|pm)/i, "<abbr>\\1</abbr>")
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
      if is_good_weather? && is_hot?
        return "It's a good day for some heat training!"
      elsif is_good_weather?
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
    condition = data.conditions[current_weather.condition_code]
    return 'cloud-question' if condition.blank?
    return condition[:icon] if condition[:icon].is_a?(String)
    is_daytime? ? condition[:icon][:day] : condition[:icon][:night]
  end
end
