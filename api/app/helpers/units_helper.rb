module UnitsHelper
  include ActiveSupport::NumberHelper

  # Changes a distance in meters into metric units or imperial units.
  # @param meters [Float] The distance in meters.
  # @param units [String] The unit system: 'si', 'metric', or 'imperial'. It is optional, and the
  #   default is 'si'.
  # @return [String] The distance as a string, in the given unit system.
  def distance(meters, units: "si")
    case units
    when "si", "metric"
      metric_distance, metric_units = meters_to_metric_units(meters)
      formatted_distance(metric_distance, metric_units, determine_precision(metric_distance))
    when "imperial"
      imperial_distance, imperial_units = meters_to_imperial_units(meters)
      formatted_distance(imperial_distance, imperial_units, determine_precision(imperial_distance))
    end
  end

  # Divides a distance into its number and its unit. Thus a view that needs both does one
  # number_to_human, and not one for each part.
  # @return [Array(String, String)] The value and the unit.
  def distance_parts(meters, units: "si")
    distance(meters, units: units).split(/\s+/, 2)
  end

  # Gets the number from the distance after the conversion.
  def distance_value(meters, units: "si")
    distance_parts(meters, units: units).first
  end

  # Gets the unit of the distance after the conversion.
  def distance_unit(meters, units: "si")
    distance_parts(meters, units: units).last
  end

  # Formats a distance number with the given unit and the given number of decimals.
  def formatted_distance(distance, units, precision)
    number_to_human(distance, units: units, precision: precision,
                    strip_insignificant_zeros: true, significant: false, delimiter: ",")
  end

  # Finds the number of decimals for a number, from its significant digits.
  def determine_precision(number, max_digits: 4, max_decimals: 1)
    significant_digits = number.to_i.digits.count
    precision = max_digits - significant_digits
    precision.clamp(0, max_decimals)
  end

  # Changes meters into kilometers or keeps meters, from the size of the value.
  def meters_to_metric_units(meters)
    kilometers = meters / 1000.0

    if kilometers < 1
      [ meters, { unit: "meter".pluralize(meters) } ]
    else
      [ kilometers, { unit: "kilometer".pluralize(kilometers) } ]
    end
  end

  # Changes a temperature from Celsius into Fahrenheit.
  def celsius_to_fahrenheit(celsius)
    (celsius * (9.0 / 5.0)) + 32
  end

  # Changes kilometers into miles.
  def kilometers_to_miles(km)
    km * 0.621371
  end

  # Changes a speed from kilometers each hour into knots.
  def kph_to_knots(kph)
    kph * 0.539957
  end

  # Changes meters into feet.
  def meters_to_feet(meters)
    meters * 3.28084
  end

  # Changes millimeters into inches.
  def millimeters_to_inches(millimeters)
    millimeters / 25.4
  end

  # Changes meters into miles or yards, from the size of the value.
  def meters_to_imperial_units(meters)
    miles = meters_to_miles(meters)
    yards = meters_to_yards(meters)

    if miles < 1
      [ yards, { unit: "yard".pluralize(yards) } ]
    else
      [ miles, { unit: "mile".pluralize(miles) } ]
    end
  end

  def meters_to_miles(meters)
    meters * 0.000621371
  end

  def meters_to_yards(meters)
    meters * 1.09361
  end
end
