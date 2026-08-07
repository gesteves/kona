# Pure forecast-selection and formatting functions: every method takes the data it works on as
# an explicit argument, and none read controller state. The CONDITIONS and BEAUFORT constants
# come from config/initializers/weather_data.rb.
#
# The prose summary and its business rules live in WeatherSummaryPresenter, which includes this
# module and passes it the request's data.
module WeatherHelper
  PRECIPITATION_METRIC_UNITS = {
    unit: "mm",
    ten: "cm",
    thousand: "m"
  }.freeze

  # Validates the exact slices the summary consumes. Checking todays_forecast alone isn't
  # enough: rest_of_day_forecast switches to the overnight forecast in the evening, so a payload
  # missing overnight data would pass and then crash the evening summary.
  def weather_data_is_current?(weather, time_zone)
    current_weather(weather).present? && todays_forecast(weather).present? && rest_of_day_forecast(weather, time_zone).present?
  end

  def weather_data_is_stale?(weather, time_zone)
    !weather_data_is_current?(weather, time_zone)
  end

  def current_weather(weather)
    weather&.current_weather
  end

  def todays_forecast(weather)
    now = Time.now
    weather&.forecast_daily&.days&.find { |d| d.rest_of_day_forecast.present? && Time.parse(d.forecast_start) <= now && Time.parse(d.forecast_end) >= now }
  end

  def rest_of_day_forecast(weather, time_zone)
    forecast = todays_forecast(weather)
    evening?(weather, time_zone) ? forecast&.overnight_forecast : forecast&.rest_of_day_forecast
  end

  def tomorrows_forecast(weather)
    now = Time.now
    weather&.forecast_daily&.days&.find { |d| Time.parse(d.forecast_start) > now }
  end

  def sunrise(weather, time_zone)
    forecast = todays_forecast(weather)
    return nil unless forecast&.sunrise
    Time.parse(forecast.sunrise).in_time_zone(time_zone)
  end

  def tomorrows_sunrise(weather, time_zone)
    forecast = tomorrows_forecast(weather)
    return nil unless forecast&.sunrise
    Time.parse(forecast.sunrise).in_time_zone(time_zone)
  end

  def sunset(weather, time_zone)
    forecast = todays_forecast(weather)
    return nil unless forecast&.sunset
    Time.parse(forecast.sunset).in_time_zone(time_zone)
  end

  # Whether it's daytime: between today's sunrise and sunset when the payload carries them,
  # else a 6am–6pm clock check.
  def daytime?(weather, time_zone)
    now = Time.current.in_time_zone(time_zone)
    if weather.present?
      sunrise_time = sunrise(weather, time_zone)
      sunset_time = sunset(weather, time_zone)
      return now.hour >= 6 && now.hour < 18 unless sunrise_time && sunset_time
      now >= sunrise_time.beginning_of_hour && now <= sunset_time.beginning_of_hour
    else
      now.hour >= 6 && now.hour < 18
    end
  end

  # Whether it's evening: past today's sunset when the payload carries it, else a 6pm check.
  def evening?(weather, time_zone)
    now = Time.current.in_time_zone(time_zone)
    if weather.present?
      sunset_time = sunset(weather, time_zone)
      return now.hour >= 18 unless sunset_time
      now >= sunset_time.beginning_of_hour
    else
      now.hour >= 18
    end
  end

  def today_or_tonight(weather, time_zone)
    evening?(weather, time_zone) ? "Tonight" : "Today"
  end

  def format_current_condition(condition_code)
    return "it's out there" if condition_code.blank?

    CONDITIONS.dig(condition_code.to_sym, :phrases, :currently) || "it's #{condition_code.underscore.gsub('_', ' ')}"
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

  # WeatherKit omits gust data for some forecast days, and the views' surrounding guards only
  # check the wind speed and direction — so this has to hold its own against a nil.
  def show_gusts?(wind_speed, gusts_speed)
    return false if wind_speed.blank? || gusts_speed.blank?

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
    content_tag(:span, BEAUFORT[number][:description].downcase, title: "Beaufort scale #{number}")
  end

  def pollen_index_value(pollen)
    pollen&.pollen_type_info&.select { |p| p&.index_info&.value.to_i > 0 }&.map { |p| p.index_info.value }&.max.to_i
  end

  def pollen_index_category(pollen)
    return "None" if pollen_index_value(pollen).zero?
    pollen.pollen_type_info&.find { |p| p&.index_info&.value.to_i == pollen_index_value(pollen) }&.index_info&.category
  end

  def format_time(time)
    meridiem_abbr(remove_widows(time.strftime("%l:%M %p")))
  end

  # The icon id for a condition code. :auto picks the day/night variant from the given
  # weather + timezone (see #daytime?); :day / :night pick explicitly and need neither.
  def weather_icon(condition_code, variant = :auto, weather: nil, time_zone: nil)
    condition = CONDITIONS[condition_code&.to_sym]
    return "cloud-question" if condition.blank?
    return condition[:icon] if condition[:icon].is_a?(String)
    if variant == :auto
      daytime?(weather, time_zone) ? condition[:icon][:day] : condition[:icon][:night]
    elsif variant == :day
      condition[:icon][:day]
    elsif variant == :night
      condition[:icon][:night]
    end
  end

  def weather_alerts(weather)
    return [] if weather&.weather_alerts&.alerts.blank?
    alerts = weather.weather_alerts.alerts.group_by { |alert| alert.token }
                    .map { |_token, grouped_alerts| grouped_alerts.min_by { |alert| alert.precedence } }
    alerts.sort_by { |alert| alert.precedence }
  end

  def aqi_icon(aqi)
    # Without this, a missing AQI falls to the `else` and renders as hazardous air.
    return "sun-haze" if aqi.blank?

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
