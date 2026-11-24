# The functions that format a weather value. Each method takes the data as an argument. CONDITIONS
# and BEAUFORT come from config/initializers/weather_data.rb.
#
# Forecast selects the data, and the text summary and its rules are in WeatherSummaryPresenter,
# which includes this module.
module WeatherHelper
  PRECIPITATION_METRIC_UNITS = {
    unit: "mm",
    ten: "cm",
    thousand: "m"
  }.freeze

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

  # @param value [Integer] The index value, from pollen_index_value. The caller can give it, thus
  #   the scan of the readings runs one time.
  # @return [String, nil] The category of the reading with that value, or nil when the reading has
  #   none.
  def pollen_index_category(pollen, value = pollen_index_value(pollen))
    return "None" if value.zero?
    pollen.pollen_type_info&.find { |p| p&.index_info&.value.to_i == value }&.index_info&.category
  end

  def format_time(time)
    meridiem_abbr(remove_widows(time.strftime("%-I:%M %p")))
  end

  # The icon id for a condition code.
  # @param variant [Symbol] :day or :night, for a code that has an icon for each.
  def weather_icon(condition_code, variant = :day)
    condition = CONDITIONS[condition_code&.to_sym]
    return "cloud-question" if condition.blank?
    return condition[:icon] if condition[:icon].is_a?(String)

    condition[:icon][variant]
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
