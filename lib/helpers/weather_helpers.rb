require 'active_support/all'

module WeatherHelpers
  include ActiveSupport::NumberHelper
  PRECIPITATION_METRIC_UNITS = {
    unit: 'mm',
    ten: 'cm',
    thousand: 'm'
  }

  # Returns if the current weather data is still current.
  # @param weather [Hash] The weather data hash.
  # @return [Boolean] True if the weather data is still current.
  def weather_data_is_current?(weather = data.weather)
    current_weather(weather).present? && todays_forecast(weather).present?
  end

  # Returns if the current weather data is stale/out of date.
  # @param weather [Hash] The weather data hash.
  # @return [Boolean] True if the weather data is stale.
  def weather_data_is_stale?(weather = data.weather)
    !weather_data_is_current?(weather)
  end

  # Retrieves the current weather conditions.
  # @param weather [Hash] The weather data hash.
  # @return [Hash, nil] The current weather conditions data, or nil if not found.
  def current_weather(weather = data.weather)
    weather&.current_weather
  end

  # Retrieves the forecast for the current day.
  # @param weather [Hash] The weather data hash.
  # @return [Hash, nil] The forecast data for today, or nil if not found.
  def todays_forecast(weather = data.weather)
    now = Time.now
    weather&.forecast_daily&.days&.find { |d| d.rest_of_day_forecast.present? && Time.parse(d.forecast_start) <= now && Time.parse(d.forecast_end) >= now }
  end

  # Returns the forecast for the rest of the day if it's daytime, or the overnight forecast after sunset.
  # @param weather [Hash] The weather data hash.
  # @return [Hash] The forecast data for the rest of the day or night.
  def rest_of_day_forecast(weather = data.weather)
    forecast = todays_forecast(weather)
    is_evening? ? forecast&.overnight_forecast : forecast&.rest_of_day_forecast
  end

  # Retrieves the forecast for tomorrow.
  # @param weather [Hash] The weather data hash.
  # @return [Hash, nil] The forecast data for tomorrow, or nil if not found.
  def tomorrows_forecast(weather = data.weather)
    now = Time.now
    weather&.forecast_daily&.days&.find { |d| Time.parse(d.forecast_start) > now }
  end

  # Retrieves the time of sunrise for today.
  # @param weather [Hash] The weather data hash.
  # @param location [Hash] The location data hash.
  # @return [Time, nil] The time of sunrise today, or nil if not found.
  def sunrise(weather = data.weather, location = data.location)
    forecast = todays_forecast(weather)
    return nil unless forecast&.sunrise
    Time.parse(forecast.sunrise).in_time_zone(location_time_zone(location))
  end

  # Retrieves the time of sunrise for tomorrow.
  # @param weather [Hash] The weather data hash.
  # @param location [Hash] The location data hash.
  # @return [Time, nil] The time of sunrise tomorrow, or nil if not found.
  def tomorrows_sunrise(weather = data.weather, location = data.location)
    forecast = tomorrows_forecast(weather)
    return nil unless forecast&.sunrise
    Time.parse(forecast.sunrise).in_time_zone(location_time_zone(location))
  end

  # Retrieves the time of sunset for today.
  # @param weather [Hash] The weather data hash.
  # @param location [Hash] The location data hash.
  # @return [Time, nil] The time of sunset today, or nil if not found.
  def sunset(weather = data.weather, location = data.location)
    forecast = todays_forecast(weather)
    return nil unless forecast&.sunset
    Time.parse(forecast.sunset).in_time_zone(location_time_zone(location))
  end

  # Checks if it is currently daytime (i.e. between sunrise and sunset).
  # @param weather [Hash] The weather data hash.
  # @param location [Hash] The location data hash.
  # @return [Boolean] true if it is daytime, false otherwise.
  def is_daytime?(weather = data.weather, location = data.location)
    now = Time.now
    if weather.present?
      sunrise_time = sunrise(weather, location)
      sunset_time = sunset(weather, location)
      return now.hour >= 6 && now.hour < 18 unless sunrise_time && sunset_time
      now >= sunrise_time.beginning_of_hour && now <= sunset_time.beginning_of_hour
    else
      now.hour >= 6 && now.hour < 18
    end
  end

  # Checks if it is currently evening (i.e. after sunset).
  # @param weather [Hash] The weather data hash.
  # @param location [Hash] The location data hash.
  # @return [Boolean] true if it is evening, false otherwise.
  def is_evening?(weather = data.weather, location = data.location)
    if weather.present?
      sunset_time = sunset(weather, location)
      return Time.now.hour >= 18 unless sunset_time
      Time.now >= sunset_time.beginning_of_hour
    else
      Time.now.hour >= 18
    end
  end

  # Determines whether to refer to the current time as "Today" or "Tonight"
  # based on the time of day (evening or not).
  # @param weather [Hash] The weather data hash.
  # @param location [Hash] The location data hash.
  # @return [String] "Today" if it's not evening, "Tonight" if it's evening.
  def today_or_tonight(weather = data.weather, location = data.location)
    is_evening?(weather, location) ? "Tonight" : "Today"
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

  # Formats the weather condition based on its condition code.
  # @param [String] condition_code - The condition code representing the weather.
  # @return [String] The formatted weather condition description.
  def format_condition(condition_code)
    data.conditions.dig(condition_code, :phrases, :simplified) || condition_code.underscore.gsub('_', ' ')
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

  # Formats a wind speed in kilometers per hour (km/h) to both metric and imperial units.
  # @param [Float] speed - The wind speed in kilometers per hour (km/h).
  # @return [String] A formatted string representing the wind speed in both metric and imperial units.
  def format_wind_speed(speed)
    wind_speed_metric = speed.round
    wind_speed_imperial = kilometers_to_miles(speed).round
    metric = "#{wind_speed_metric} km/h"
    imperial = "#{wind_speed_imperial} mph"
    units_tag(metric, imperial)
  end

  # Formats a wind speed range in kilometers per hour (km/h) to both metric and imperial units.
  # @param [Float] min - The minimum wind speed in kilometers per hour (km/h).
  # @param [Float] max - The maximum wind speed in kilometers per hour (km/h).
  # @return [String] A formatted string representing the wind speed range in both metric and imperial units.
  def format_wind_speed_range(min, max)
    return nil if min.blank? && max.blank?
    return format_wind_speed(max) if min.blank?
    return format_wind_speed(min) if max.blank?
    return format_wind_speed(min) if min == max

    min_metric = min.round
    min_imperial = kilometers_to_miles(min).round
    max_metric = max.round
    max_imperial = kilometers_to_miles(max).round

    metric = "#{min_metric}–#{max_metric} km/h"
    imperial = "#{min_imperial}–#{max_imperial} mph"
    units_tag(metric, imperial)
  end

  # Determines if the gusts should be shown based on the wind speed and gusts speed.
  # @param [Float] wind_speed - The wind speed in kilometers per hour (km/h).
  # @param [Float] gusts_speed - The gusts speed in kilometers per hour (km/h).
  # @return [Boolean] True if the gusts should be shown, false otherwise.
  def show_gusts?(wind_speed, gusts_speed)
    wind_speed_knots = kph_to_knots(wind_speed)
    gusts_knots = kph_to_knots(gusts_speed)

    gusts_knots >= 16 && gusts_knots >= wind_speed_knots + 9
  end

  # Converts a wind direction in degrees to a cardinal direction.
  # @param [Integer] degrees - The wind direction in degrees.
  # @param [Boolean] abbreviated - Whether to return the abbreviated direction.
  # @return [String] The cardinal direction corresponding to the wind direction.
  def wind_direction(degrees, abbreviated = false)
    case degrees
    when 0..22.5, 337.5..360
      abbreviated ? "N" : "North"
    when 22.5..67.5
      abbreviated ? "NE" : "Northeast"
    when 67.5..112.5
      abbreviated ? "E" : "East"
    when 112.5..157.5
      abbreviated ? "SE" : "Southeast"
    when 157.5..202.5
      abbreviated ? "S" : "South"
    when 202.5..247.5
      abbreviated ? "SW" : "Southwest"
    when 247.5..292.5
      abbreviated ? "W" : "West"
    when 292.5..337.5
      abbreviated ? "NW" : "Northwest"
    else
      nil
    end
  end

  # Method to convert wind speed in knots to Beaufort scale number (0-12)
  # @param [Float] The wind speed in knots
  # @return [Integer] The Beaufort scale number (0-12)
  def beaufort_number(knots)
    beaufort = (knots / 1.625) ** (2.0 / 3.0)
    beaufort.round.clamp(0, 12)
  end

  # Method to get Beaufort scale description from YAML file based on the wind speed.
  # @param [Float] The wind speed in knots
  # @return [String] The Beaufort scale description
  def beaufort_description(knots)
    beaufort_number = beaufort_number(knots)

    content_tag :span, title: "Beaufort scale #{beaufort_number}" do
      data.beaufort[beaufort_number]['description'].downcase
    end
  end

  # Returns the pollen index value, from 0 to 5.
  # @see https://developers.google.com/maps/documentation/pollen/reference/rest/v1/forecast/lookup#indexinfo
  # @return [Integer] The pollen index, where 0 is "none", and 5 is "very high"
  def pollen_index_value
    data.pollen&.pollen_type_info&.select { |p| p&.index_info&.value.to_i > 0 }&.map { |p| p.index_info.value }&.max.to_i
  end

  # Returns the pollen index category, from "none" to "very high".
  # @see https://developers.google.com/maps/documentation/pollen/reference/rest/v1/forecast/lookup#indexinfo
  # @return [String] The pollen index category.
  def pollen_index_category
    return "None" if pollen_index_value.zero?
    data.pollen.pollen_type_info&.find { |p| p&.index_info&.value.to_i == pollen_index_value }&.index_info.category
  end

  # Returns the pollen level's description as a sentence.
  # @return [String, nil] Description of the highest pollen level or nil.
  def format_pollen_level
    return if pollen_index_value.zero?
    "Pollen levels are #{pollen_index_category.downcase}"
  end

  # Determines if the current weather conditions are considered "bad" for working out outdoors.
  # @return [Boolean] `true` if the weather conditions are bad, `false` otherwise.
  def is_bad_weather?
    aqi = data&.air_quality&.aqi.to_i
    current_temperature = (current_weather.temperature_apparent || current_weather.temperature)
    high_temperature = todays_forecast.temperature_max
    low_temperature = todays_forecast.temperature_min
    precipitation_chance = rest_of_day_forecast.precipitation_chance
    snowfall = rest_of_day_forecast.snowfall_amount
    beaufort_number = beaufort_number(kph_to_knots(current_weather.wind_speed))

    # Air quality is worse than moderate
    return true if aqi > 100
    # Current temp is too cold or too hot
    return true if current_temperature <= -12 || current_temperature >= 35
    # Forecasted low temp is too cold
    return true if low_temperature <= -12
    # Forecasted high temp is too cold or too hot
    return true if high_temperature <= 0 || high_temperature >= 35
    # It's likely to rain
    return true if precipitation_chance >= 0.5
    # Too windy
    return true if beaufort_number >= 4
    # There's gonna be accumulating snow
    return true if snowfall > 0
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
    summary = []
    summary << race_day
    summary << smooth
    summary << current_location
    summary << elevation
    summary << currently
    summary << current_aqi
    summary << format_pollen_level
    summary << forecast
    summary << precipitation
    summary << sunrise_or_sunset
    summary << activities
    summary << live_tracking
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
    location = "I'm currently in **#{format_location}**"
    the = todays_race&.title&.downcase&.start_with?("ironman") ? "" : "the"
    location << ", racing #{the} **#{todays_race.title}**" if is_race_day? && !is_evening?
    location
  end

  def elevation
    return if format_elevation.blank?
    "The elevation is #{format_elevation}"
  end

  # Determines if it's a hot one.
  # @return [String, nil] The opening words of the Grammy-award winning 1999 hit SMOOTH by Santana featuring Rob Thomas of Matchbox Twenty off the multi-platinum album Supernatural.
  def smooth
    "Man, it's a hot one!" if !is_race_day? && is_hot? && is_daytime?
  end

  # Provides a summary of current weather conditions.
  # @return [String, nil] A string describing the current weather conditions or nil if no data is available.
  def currently
    text = []
    text << "#{format_current_condition(current_weather.condition_code).capitalize}, with a temperature of #{format_temperature(current_weather.temperature)}"
    text << "which feels like #{format_temperature(current_weather.temperature_apparent)}" unless hide_apparent_temperature?
    text << "#{number_to_percentage(current_weather.humidity * 100, precision: 0)} humidity" unless current_weather.humidity.blank? || current_weather.humidity.zero?
    text << wind
    comma_join_with_and(text.compact)
  end

  # Provides a summary of the current wind conditions.
  # @return [String] A string describing the current wind conditions.
  def wind
    direction = wind_direction(current_weather.wind_direction)
    formatted_wind_speed = format_wind_speed(current_weather.wind_speed)
    wind_speed_knots = kph_to_knots(current_weather.wind_speed)

    gusts_speed = current_weather&.wind_gust.to_f
    formatted_gusts = format_wind_speed(gusts_speed)

    return if direction.blank? || beaufort_number(wind_speed_knots).zero?

    text = []
    text << "#{beaufort_description(wind_speed_knots)} of #{formatted_wind_speed} from the #{direction.downcase}"

    if show_gusts?(current_weather.wind_speed, gusts_speed)
      text << "with #{formatted_gusts} gusts"
    end

    text.join(', ')
  end

  # Provides a summary of the current Air Quality Index (AQI).
  # @return [String, nil] A string describing the current AQI or nil if no data is available.
  def current_aqi
    return if data&.air_quality&.aqi.blank?
    if data.air_quality.aqi > 500
      "The air quality is so hazardous it's beyond the <abbr title=\"Air Quality Index\">AQI</abbr>"
    else
      "The air quality is #{data.air_quality.category.downcase}, with an <abbr title=\"Air Quality Index\">AQI</abbr> of #{data.air_quality.aqi}"
    end
  end

  # Provides the weather forecast for today or tonight.
  # @return [String, nil] A string describing the weather forecast for today or tonight, or nil if no data is available.
  def forecast
    text = []
    text << "#{today_or_tonight}'s forecast #{format_forecasted_condition(rest_of_day_forecast.condition_code).downcase}"
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
    return if rest_of_day_forecast.precipitation_chance == 0 || rest_of_day_forecast.precipitation_type.downcase == 'clear'
    percentage_string = number_to_percentage(rest_of_day_forecast.precipitation_chance * 100, precision: 0)
    text = []
    text << "There's #{with_indefinite_article(percentage_string)} chance of #{format_precipitation_type(rest_of_day_forecast.precipitation_type)} later #{today_or_tonight.downcase}"
    text << "with #{format_precipitation_amount(rest_of_day_forecast.snowfall_amount)} expected" if rest_of_day_forecast.precipitation_type.downcase == 'snow' && rest_of_day_forecast.snowfall_amount > 0
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

  # Checks if it's indoor training season in Jackson Hole.
  # Indoor season is from November through March.
  # @return [Boolean] True if it's indoor season, false otherwise.
  def is_indoor_season?
    in_jackson_hole? && (Time.now.month <= 3 || Time.now.month >= 11)
  end

  # Determines the weather icon to display based on current weather conditions.
  # @param condition_code [String] The condition code to use for the icon.
  # @param variant [Symbol] The variant of the icon to display.
  # @param weather [Hash] The weather data hash.
  # @param location [Hash] The location data hash.
  # @return [String] The name of the weather icon to display.
  def weather_icon(condition_code = current_weather&.condition_code, variant = :auto, weather = data.weather, location = data.location)
    condition = data.conditions[condition_code]
    return 'cloud-question' if condition.blank?
    return condition[:icon] if condition[:icon].is_a?(String)
    if variant == :auto
      is_daytime?(weather, location) ? condition[:icon][:day] : condition[:icon][:night]
    elsif variant == :day
      condition[:icon][:day]
    elsif variant == :night
      condition[:icon][:night]
    end
  end

  # Returns an array of the weather alerts, sorted by precedence.
  #
  # @return [Array] An array of alert objects, sorted by precedence from lowest to highest.
  #                 Returns an empty array if there are no alerts.
  def weather_alerts
    return [] if data.weather&.weather_alerts&.alerts.blank?
    # Dedup alerts by token and precedence
    alerts = data.weather.weather_alerts.alerts.group_by { |alert| alert.token }
                                    .map { |token, grouped_alerts| grouped_alerts.min_by { |alert| alert.precedence } }
    # Sort the remaining alerts by precedence
    alerts.sort_by { |alert| alert.precedence }
  end

  # Generates a live tracking link.
  # @return [String] A string containing the live tracking link.
  def live_tracking
    return unless is_trackable?(todays_race)
    content_tag :span, class: "weather__highlight weather__highlight--live" do
      "#{content_tag(:a, "Live results", href: todays_race.tracking_url, rel: "noopener", target: "_blank")} #{icon_svg("classic", "solid", "circle-small")}"
    end
  end

  # Returns the icon for the AQI.
  # @param aqi [Integer] The AQI value.
  # @return [String] The icon for the AQI.
  def aqi_icon(aqi)
    case aqi
    when 0..50
      "sun-haze"
    when 51..150
      "smog"
    when 151..200
      "smoke"
    else
      "fire-smoke"
    end
  end
end
