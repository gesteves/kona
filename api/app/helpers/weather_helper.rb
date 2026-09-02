# The functions that select a forecast and that format a value. Each method takes the data as an
# argument, and none of them reads the state of a controller. The CONDITIONS constant and the
# BEAUFORT constant come from config/initializers/weather_data.rb.
#
# The text summary and its rules are in WeatherSummaryPresenter, which includes this module and
# gives it the data of the request.
module WeatherHelper
  PRECIPITATION_METRIC_UNITS = {
    unit: "mm",
    ten: "cm",
    thousand: "m"
  }.freeze

  # Checks the exact parts of the data that the summary uses. A check of todays_forecast alone is
  # not sufficient: rest_of_day_forecast changes to the overnight forecast in the evening. Thus a
  # payload with no overnight data would pass this check and then stop the evening summary.
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

  # Tells if it is daytime: between the sunrise and the sunset of today, when the payload has those
  # two times. In all other conditions, it tests the clock against 6am and 6pm.
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

  # Tells if it is evening: after the sunset of today, when the payload has that time. In all other
  # conditions, it tests the clock against 6pm.
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

  # ⚠️ This accepts nil, for the same reason as format_temperature.
  def format_forecasted_condition(condition_code)
    return if condition_code.blank?

    CONDITIONS.dig(condition_code.to_sym, :phrases, :forecast) || "calls for #{condition_code.underscore.gsub('_', ' ')}"
  end

  # ⚠️ This accepts nil, for the same reason as format_temperature.
  def format_condition(condition_code)
    return if condition_code.blank?

    CONDITIONS.dig(condition_code.to_sym, :phrases, :simplified) || condition_code.underscore.gsub("_", " ")
  end

  # ⚠️ This returns nil for a reading that is absent, and it does not raise. Each upstream service
  # omits some fields, and the arithmetic below makes one of those into a NoMethodError, which gives
  # the full widget a 500. A caller must still test each field, or the page shows a label with no
  # number.
  def format_temperature(temp)
    return if temp.blank?
    celsius = "#{number_to_human(temp, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}°C"
    fahrenheit = "#{number_to_human(celsius_to_fahrenheit(temp), precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ',')}°F"
    units_tag(celsius, fahrenheit)
  end

  # ⚠️ This accepts nil, for the same reason as format_temperature.
  def format_precipitation_amount(mm)
    return if mm.blank?

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
      human_inches = number_to_human(inches, precision: 0, strip_insignificant_zeros: true, significant: false, delimiter: ",")
      amount = human_inches == "1" ? "#{human_inches} inch" : "#{human_inches} inches"
      "about #{amount}"
    end

    units_tag(metric, imperial)
  end

  # ⚠️ This accepts nil, for the same reason as format_temperature.
  def format_precipitation_type(type)
    return if type.blank?

    case type.downcase
    when "clear"
      "precipitation"
    when "mixed"
      "wintry mix"
    else
      type.downcase
    end
  end

  # ⚠️ This accepts nil, for the same reason as format_temperature.
  def format_wind_speed(speed)
    return if speed.blank?
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

  # WeatherKit omits the gust data on some forecast days, and the checks in the views test only the
  # wind speed and the wind direction. Thus this method must accept a nil.
  def show_gusts?(wind_speed, gusts_speed)
    return false if wind_speed.blank? || gusts_speed.blank?

    wind_speed_knots = kph_to_knots(wind_speed)
    gusts_knots = kph_to_knots(gusts_speed)
    gusts_knots >= 16 && gusts_knots >= wind_speed_knots + 9
  end

  # Each band is half open, thus a value on a boundary goes to the next point of the compass.
  def wind_direction(degrees, abbreviated = false)
    case degrees
    when 0...22.5, 337.5..360
      abbreviated ? "N" : "North"
    when 22.5...67.5
      abbreviated ? "NE" : "Northeast"
    when 67.5...112.5
      abbreviated ? "E" : "East"
    when 112.5...157.5
      abbreviated ? "SE" : "Southeast"
    when 157.5...202.5
      abbreviated ? "S" : "South"
    when 202.5...247.5
      abbreviated ? "SW" : "Southwest"
    when 247.5...292.5
      abbreviated ? "W" : "West"
    when 292.5...337.5
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

  # The icon id for a condition code. :auto selects the day icon or the night icon from the given
  # weather and timezone (refer to #daytime?). :day and :night select one directly and need
  # neither.
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
    # Without this, an AQI that is absent goes to the `else` and shows as dangerous air.
    return "sun-haze" if aqi.blank?

    # The bands take a fraction: an AQI can be a float.
    case aqi
    when ..50
      "sun-haze"
    when ..150
      "smog"
    when ..200
      "smoke"
    else
      "fire-smoke"
    end
  end
end
