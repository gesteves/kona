module UnitsHelper
  include ActiveSupport::NumberHelper

  # Converts a distance in meters to either metric or imperial units.
  # @param meters [Float] The distance in meters to be converted.
  # @param units [String] (Optional) The unit system: 'si', 'metric', or 'imperial'. Default is 'si'.
  # @return [String] The distance formatted as a string in the specified unit system.
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

  # Extracts the numerical value of the converted distance.
  def distance_value(meters, units: "si")
    distance(meters, units: units).split(/\s+/).first
  end

  # Retrieves the unit of measurement for the converted distance.
  def distance_unit(meters, units: "si")
    distance(meters, units: units).split(/\s+/).last
  end

  # Formats a distance number with specified units and precision.
  def formatted_distance(distance, units, precision)
    number_to_human(distance, units: units, precision: precision,
                    strip_insignificant_zeros: true, significant: false, delimiter: ",")
  end

  # Determines the precision for formatting a number based on significant digits.
  def determine_precision(number, max_digits: 4, max_decimals: 1)
    significant_digits = number.to_i.digits.count
    precision = max_digits - significant_digits
    precision.clamp(0, max_decimals)
  end

  # Converts meters to kilometers or meters based on magnitude.
  def meters_to_metric_units(meters)
    kilometers = meters / 1000.0

    if kilometers < 1
      [meters, { unit: "meter".pluralize(meters) }]
    else
      [kilometers, { unit: "kilometer".pluralize(kilometers) }]
    end
  end

  # Converts a temperature from Celsius to Fahrenheit.
  def celsius_to_fahrenheit(celsius)
    (celsius * (9.0 / 5.0)) + 32
  end

  # Converts kilometers to miles.
  def kilometers_to_miles(km)
    km * 0.621371
  end

  # Converts a speed from kilometers per hour to knots.
  def kph_to_knots(kph)
    kph * 0.539957
  end

  # Converts meters to feet.
  def meters_to_feet(meters)
    meters * 3.28084
  end

  # Converts millimeters to inches.
  def millimeters_to_inches(millimeters)
    millimeters / 25.4
  end

  # Converts meters to miles or yards based on magnitude.
  def meters_to_imperial_units(meters)
    miles = meters_to_miles(meters)
    yards = meters_to_yards(meters)

    if miles < 1
      [yards, { unit: "yard".pluralize(yards) }]
    else
      [miles, { unit: "mile".pluralize(miles) }]
    end
  end

  def meters_to_miles(meters)
    meters * 0.000621371
  end

  def meters_to_yards(meters)
    meters * 1.09361
  end
end
