require 'active_support/all'

module UnitHelpers
  include ActiveSupport::NumberHelper
  # Converts a distance in meters to either metric or imperial units.
  # @param meters [Float] The distance in meters to be converted.
  # @param units [String] (Optional) The unit system for conversion: 'si', 'metric', or 'imperial'. Default is 'si'.
  # @return [String] The distance converted into the specified unit system, formatted as a string.
  def distance(meters, units: 'si')
    case units
    when 'si', 'metric'
      metric_distance, metric_units = meters_to_metric_units(meters)
      formatted_distance(metric_distance, metric_units, determine_precision(metric_distance))
    when 'imperial'
      imperial_distance, imperial_units = meters_to_imperial_units(meters)
      formatted_distance(imperial_distance, imperial_units, determine_precision(imperial_distance))
    end
  end

  # Extracts the numerical value of the converted distance from meters to specified units.
  # @param meters [Float] The distance in meters to be converted.
  # @param units [String] (Optional) The unit system for conversion: 'si', 'metric', or 'imperial'. Default is 'si'.
  # @return [String] The numerical value of the distance in the specified unit system.
  def distance_value(meters, units: 'si')
    distance(meters, units: units).split(/\s+/).first
  end

  # Retrieves the unit of measurement for the converted distance from meters to specified units.
  # @param meters [Float] The distance in meters to be converted.
  # @param units [String] (Optional) The unit system for conversion: 'si', 'metric', or 'imperial'. Default is 'si'.
  # @return [String] The unit of measurement for the distance in the specified unit system.
  def distance_unit(meters, units: 'si')
    distance(meters, units: units).split(/\s+/).last
  end

  # Formats a distance number with specified units and precision.
  # @param distance [Float] The distance to be formatted.
  # @param units [String] The unit of measurement for the distance.
  # @param precision [Integer] The precision level for formatting the distance.
  # @return [String] The distance formatted as a human-readable string with specified units and precision.
  def formatted_distance(distance, units, precision)
    number_to_human(distance, units: units, precision: precision,
                    strip_insignificant_zeros: true, significant: false, delimiter: ',')
  end

  # Determines the precision for formatting a number based on significant digits.
  # @param number [Float] The number for which to determine precision.
  # @param max_digits [Integer] (Optional) The maximum total digits to consider. Default is 4.
  # @param max_decimals [Integer] (Optional) The maximum decimal places to consider. Default is 1.
  # @return [Integer] The calculated precision, constrained within the specified limits.
  def determine_precision(number, max_digits: 4, max_decimals: 1)
    significant_digits = number.to_i.digits.count
    precision = max_digits - significant_digits
    precision.clamp(0, max_decimals)
  end

  # Converts a distance from meters to kilometers or meters based on the distance magnitude.
  # @param meters [Float] The distance in meters to be converted.
  # @return [Array] An array containing the converted distance and its unit (either meters or kilometers).
  def meters_to_metric_units(meters)
    kilometers = meters / 1000.0

    if kilometers < 1
      [meters, { unit: 'meter'.pluralize(meters) }]
    else
      [kilometers, { unit: 'kilometer'.pluralize(kilometers) }]
    end
  end

  # Converts a distance from meters to miles or yards based on the distance magnitude.
  # @param meters [Float] The distance in meters to be converted.
  # @return [Array] An array containing the converted distance and its unit (either miles or yards).
  def meters_to_imperial_units(meters)
    miles = meters_to_miles(meters)
    yards = meters_to_yards(meters)

    if miles < 1
      [yards, { unit: 'yard'.pluralize(yards) }]
    else
      [miles, { unit: 'mile'.pluralize(miles) }]
    end
  end

  # Converts a distance from meters to miles.
  # @param meters [Float] The distance in meters to be converted.
  # @return [Float] The distance in miles.
  def meters_to_miles(meters)
    meters * 0.000621371
  end

  # Converts a distance from kilometers to miles.
  # @param meters [Float] The distance in kilometers to be converted.
  # @return [Float] The distance in miles.
  def kilometers_to_miles(km)
    km * 0.621371
  end

  # Converts a speed from kilometers per hour to knots.
  # @param kph [Float] The speed in kilometers per hour to be converted.
  # @return [Float] The speed in knots.
  def kph_to_knots(kph)
    kph * 0.539957
  end

  # Converts a distance from meters to yards.
  # @param meters [Float] The distance in meters to be converted.
  # @return [Float] The distance in yards.
  def meters_to_yards(meters)
    meters * 1.09361
  end

  # Converts a distance from meters to feet.
  # @param meters [Float] The distance in meters to be converted.
  # @return [Float] The distance in feet.
  def meters_to_feet(meters)
    meters * 3.28084
  end

  # Converts millimeters to inches.
  # @param millimeters [Float] The length in millimeters.
  # @return [Float] The equivalent length in inches.
  def millimeters_to_inches(millimeters)
    millimeters / 25.4
  end

  # Converts a temperature value from Celsius to Fahrenheit.
  # @param [Float] celsius - The temperature value in Celsius.
  # @return [Float] The equivalent temperature value in Fahrenheit.
  def celsius_to_fahrenheit(celsius)
    (celsius * (9.0 / 5.0)) + 32
  end
end
