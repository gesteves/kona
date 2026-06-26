# Ported from web/lib/helpers/weather_helpers.rb. Reads controller-set ivars (@weather,
# @air_quality, @pollen, @location) instead of Middleman's data.*, and the CONDITIONS /
# BEAUFORT constants (config/initializers/weather_data.rb) instead of data.conditions /
# data.beaufort. Condition codes (e.g. "Rain") are looked up symbolized.
module WeatherHelper
  PRECIPITATION_METRIC_UNITS = {
    unit: "mm",
    ten: "cm",
    thousand: "m"
  }.freeze

  def weather_data_is_current?(weather = @weather)
    current_weather(weather).present? && todays_forecast(weather).present?
  end

  def weather_data_is_stale?(weather = @weather)
    !weather_data_is_current?(weather)
  end

  def current_weather(weather = @weather)
    weather&.current_weather
  end

  def todays_forecast(weather = @weather)
    now = Time.now
    weather&.forecast_daily&.days&.find { |d| d.rest_of_day_forecast.present? && Time.parse(d.forecast_start) <= now && Time.parse(d.forecast_end) >= now }
  end

  def rest_of_day_forecast(weather = @weather)
    forecast = todays_forecast(weather)
    is_evening? ? forecast&.overnight_forecast : forecast&.rest_of_day_forecast
  end

  def tomorrows_forecast(weather = @weather)
    now = Time.now
    weather&.forecast_daily&.days&.find { |d| Time.parse(d.forecast_start) > now }
  end

  def sunrise(weather = @weather, location = @location)
    forecast = todays_forecast(weather)
    return nil unless forecast&.sunrise
    Time.parse(forecast.sunrise).in_time_zone(location_time_zone(location))
  end

  def tomorrows_sunrise(weather = @weather, location = @location)
    forecast = tomorrows_forecast(weather)
    return nil unless forecast&.sunrise
    Time.parse(forecast.sunrise).in_time_zone(location_time_zone(location))
  end

  def sunset(weather = @weather, location = @location)
    forecast = todays_forecast(weather)
    return nil unless forecast&.sunset
    Time.parse(forecast.sunset).in_time_zone(location_time_zone(location))
  end

  def is_daytime?(weather = @weather, location = @location)
    now = current_time
    if weather.present?
      sunrise_time = sunrise(weather, location)
      sunset_time = sunset(weather, location)
      return now.hour >= 6 && now.hour < 18 unless sunrise_time && sunset_time
      now >= sunrise_time.beginning_of_hour && now <= sunset_time.beginning_of_hour
    else
      now.hour >= 6 && now.hour < 18
    end
  end

  def is_evening?(weather = @weather, location = @location)
    now = current_time
    if weather.present?
      sunset_time = sunset(weather, location)
      return now.hour >= 18 unless sunset_time
      now >= sunset_time.beginning_of_hour
    else
      now.hour >= 18
    end
  end

  def today_or_tonight(weather = @weather, location = @location)
    is_evening?(weather, location) ? "Tonight" : "Today"
  end

  def format_current_condition(condition_code)
    CONDITIONS.dig(condition_code&.to_sym, :phrases, :currently) || "it's #{condition_code.underscore.gsub('_', ' ')}"
  end

  def format_forecasted_condition(condition_code)
    CONDITIONS.dig(condition_code&.to_sym, :phrases, :forecast) || "calls for #{condition_code.underscore.gsub('_', ' ')}"
  end

  def format_condition(condition_code)
    CONDITIONS.dig(condition_code&.to_sym, :phrases, :simplified) || condition_code.underscore.gsub("_", " ")
  end

  def format_temperature(temp)
    celsius = "#{number_to_human(temp, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}°C"
    fahrenheit = "#{number_to_human(celsius_to_fahrenheit(temp), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}°F"
    units_tag(celsius, fahrenheit)
  end

  def format_precipitation_amount(mm)
    metric = if mm < 10
      "less than a centimeter"
    else
      amount = number_to_human(mm, units: PRECIPITATION_METRIC_UNITS, precision: (mm > 1000 ? 1 : 0), strip_insignificant_zeros: true, significant: false, delimiter: ",")
      "about #{amount}"
    end

    inches = millimeters_to_inches(mm)
    imperial = if inches < 1
      "less than an inch"
    else
      human_inches = number_to_human(inches, precision: (inches < 1 ? 1 : 0), strip_insignificant_zeros: true, significant: false, delimiter: ",")
      amount = human_inches == "1" ? "#{human_inches} inch" : "#{human_inches} inches"
      "about #{amount}"
    end

    units_tag(metric, imperial)
  end

  def format_precipitation_type(type)
    case type.downcase
    when "clear"
      "precipitation"
    when "mixed"
      "wintry mix"
    else
      type.downcase
    end
  end

  def format_wind_speed(speed)
    wind_speed_metric = speed.round
    wind_speed_imperial = kilometers_to_miles(speed).round
    metric = "#{wind_speed_metric} km/h"
    imperial = "#{wind_speed_imperial} mph"
    units_tag(metric, imperial)
  end

  def format_wind_speed_range(min, max)
    return nil if min.blank? && max.blank?
    return format_wind_speed(max) if min.blank?
    return format_wind_speed(min) if max.blank?

    min_metric = min.round
    min_imperial = kilometers_to_miles(min).round
    max_metric = max.round
    max_imperial = kilometers_to_miles(max).round

    metric = min_metric == max_metric ? "#{min_metric} km/h" : "#{min_metric}–#{max_metric} km/h"
    imperial = min_imperial == max_imperial ? "#{min_imperial} mph" : "#{min_imperial}–#{max_imperial} mph"
    units_tag(metric, imperial)
  end

  def show_gusts?(wind_speed, gusts_speed)
    wind_speed_knots = kph_to_knots(wind_speed)
    gusts_knots = kph_to_knots(gusts_speed)
    gusts_knots >= 16 && gusts_knots >= wind_speed_knots + 9
  end

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
    end
  end

  def beaufort_number(knots)
    beaufort = (knots / 1.625)**(2.0 / 3.0)
    beaufort.round.clamp(0, 12)
  end

  def beaufort_description(knots)
    number = beaufort_number(knots)
    content_tag :span, title: "Beaufort scale #{number}" do
      BEAUFORT[number][:description].downcase
    end
  end

  def pollen_index_value
    @pollen&.pollen_type_info&.select { |p| p&.index_info&.value.to_i > 0 }&.map { |p| p.index_info.value }&.max.to_i
  end

  def pollen_index_category
    return "None" if pollen_index_value.zero?
    @pollen.pollen_type_info&.find { |p| p&.index_info&.value.to_i == pollen_index_value }&.index_info.category
  end

  def format_pollen_level
    return if pollen_index_value.zero?
    "Pollen levels are #{pollen_index_category.downcase}"
  end

  def is_bad_weather?
    aqi = @air_quality&.aqi.to_i
    current_temperature = (current_weather.temperature_apparent || current_weather.temperature)
    high_temperature = todays_forecast.temperature_max
    low_temperature = todays_forecast.temperature_min
    precipitation_chance = rest_of_day_forecast.precipitation_chance
    snowfall = rest_of_day_forecast.snowfall_amount
    beaufort = beaufort_number(kph_to_knots(current_weather.wind_speed))

    return true if aqi > 100
    return true if current_temperature <= -12 || current_temperature >= 35
    return true if low_temperature <= -12
    return true if high_temperature <= 0 || high_temperature >= 35
    return true if precipitation_chance >= 0.5
    return true if beaufort >= 4
    return true if snowfall > 0
    CONDITIONS.dig(current_weather.condition_code&.to_sym, :adverse_weather) || CONDITIONS.dig(todays_forecast.condition_code&.to_sym, :adverse_weather)
  end

  def is_good_weather?
    !is_bad_weather?
  end

  def is_hot?
    current_weather.temperature >= 30 || current_weather.temperature_apparent >= 30
  end

  def hide_apparent_temperature?
    celsius_temp = current_weather.temperature.round
    celsius_apparent = current_weather.temperature_apparent.round
    fahrenheit_temp = celsius_to_fahrenheit(current_weather.temperature).round
    fahrenheit_apparent = celsius_to_fahrenheit(current_weather.temperature_apparent).round
    celsius_temp == celsius_apparent || fahrenheit_temp == fahrenheit_apparent
  end

  def weather_summary
    summary = []
    summary << race_day
    summary << smooth
    summary << current_location
    summary << elevation
    summary << currently
    summary << bay_water_temperature_sentence
    summary << current_aqi
    summary << format_pollen_level
    summary << forecast
    summary << precipitation
    summary << sunrise_or_sunset
    summary << activities
    markdown_to_html(summary.reject(&:blank?).map { |t| "<span>#{t}</span>" }.join(" "))
  end

  def race_day
    "**It's race day!**" if is_race_day? && !is_evening?
  end

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

  def smooth
    "Man, it's a hot one!" if !is_race_day? && is_hot? && is_daytime?
  end

  def currently
    text = []
    text << "#{format_current_condition(current_weather.condition_code).capitalize}, with a temperature of #{format_temperature(current_weather.temperature)}"
    text << "which feels like #{format_temperature(current_weather.temperature_apparent)}" unless hide_apparent_temperature?
    text << "#{number_to_percentage(current_weather.humidity * 100, precision: 0)} humidity" unless current_weather.humidity.blank? || current_weather.humidity.zero?
    text << wind
    comma_join_with_and(text.compact)
  end

  def wind
    direction = wind_direction(current_weather.wind_direction)
    formatted_wind_speed = format_wind_speed(current_weather.wind_speed)
    wind_speed_knots = kph_to_knots(current_weather.wind_speed)

    gusts_speed = current_weather&.wind_gust.to_f
    formatted_gusts = format_wind_speed(gusts_speed)

    return if direction.blank? || beaufort_number(wind_speed_knots).zero?

    text = []
    text << "#{beaufort_description(wind_speed_knots)} of #{formatted_wind_speed} from the #{direction.downcase}"
    text << "with #{formatted_gusts} gusts" if show_gusts?(current_weather.wind_speed, gusts_speed)
    text.join(", ")
  end

  def current_aqi
    return if @air_quality&.aqi.blank?
    if @air_quality.aqi > 500
      "The air quality is so hazardous it's beyond the <abbr title=\"Air Quality Index\">AQI</abbr>"
    else
      "The air quality is #{@air_quality.category.downcase}, with an <abbr title=\"Air Quality Index\">AQI</abbr> of #{@air_quality.aqi}"
    end
  end

  def forecast
    text = []
    text << "#{today_or_tonight}'s forecast #{format_forecasted_condition(rest_of_day_forecast.condition_code).downcase}"
    if is_evening?
      text << "with a low of #{format_temperature(todays_forecast.temperature_min)}"
    else
      text << "with a high of #{format_temperature(todays_forecast.temperature_max)} and a low of #{format_temperature(todays_forecast.temperature_min)}"
    end
    text.join(", ")
  end

  def precipitation
    return if rest_of_day_forecast.precipitation_chance == 0 || rest_of_day_forecast.precipitation_type.downcase == "clear"
    percentage_string = number_to_percentage(rest_of_day_forecast.precipitation_chance * 100, precision: 0)
    text = []
    text << "There's #{with_indefinite_article(percentage_string)} chance of #{format_precipitation_type(rest_of_day_forecast.precipitation_type)} later #{today_or_tonight.downcase}"
    text << "with #{format_precipitation_amount(rest_of_day_forecast.snowfall_amount)} expected" if rest_of_day_forecast.precipitation_type.downcase == "snow" && rest_of_day_forecast.snowfall_amount > 0
    text.join(", ")
  end

  def sunrise_or_sunset
    now = Time.now
    return "Sunrise will be at #{format_time(sunrise)}" if now <= sunrise.beginning_of_hour
    return "Sunset will be at #{format_time(sunset)}" if now >= sunrise.beginning_of_hour && now < sunset.beginning_of_hour
    return "Sunrise will be at #{format_time(tomorrows_sunrise)}" if now >= sunset.beginning_of_hour
  end

  def format_time(time)
    remove_widows(time.strftime("%l:%M %p")).gsub(/(am|pm)/i, "<abbr>\\1</abbr>")
  end

  def activities
    return unless is_daytime?

    if is_race_day?
      return is_good_weather? ? "Good weather for racing!" : "Tough weather for racing!"
    end

    if is_indoor_season?
      return is_workout_scheduled? ? "It's a good day to train indoors!" : "It's a good day to rest!"
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

    is_good_weather? ? "It's a good day to be outside!" : "It's a good day to rest!"
  end

  def is_indoor_season?
    in_jackson_hole? && (Time.now.month <= 3 || Time.now.month >= 11)
  end

  def weather_icon(condition_code = current_weather&.condition_code, variant = :auto, weather = @weather, location = @location)
    condition = CONDITIONS[condition_code&.to_sym]
    return "cloud-question" if condition.blank?
    return condition[:icon] if condition[:icon].is_a?(String)
    if variant == :auto
      is_daytime?(weather, location) ? condition[:icon][:day] : condition[:icon][:night]
    elsif variant == :day
      condition[:icon][:day]
    elsif variant == :night
      condition[:icon][:night]
    end
  end

  def weather_alerts
    return [] if @weather&.weather_alerts&.alerts.blank?
    alerts = @weather.weather_alerts.alerts.group_by { |alert| alert.token }
                     .map { |_token, grouped_alerts| grouped_alerts.min_by { |alert| alert.precedence } }
    alerts.sort_by { |alert| alert.precedence }
  end

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
