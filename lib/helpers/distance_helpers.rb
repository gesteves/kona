module DistanceHelpers

  DISTANCE_UNITS = {
    unit: 'meters',
    thousand: 'kilometers'
  }

  def distance(meters, units: 'si')
    case units
    when 'si', 'metric'
      formatted_distance(meters, DISTANCE_UNITS, determine_precision(meters))
    when 'imperial'
      imperial_distance, imperial_units = imperial_conversion(meters)
      formatted_distance(imperial_distance, imperial_units, determine_precision(imperial_distance))
    end
  end

  def distance_value(meters, units: 'si')
    distance(meters, units: units).split(/\s+/).first
  end

  def distance_unit(meters, units: 'si')
    distance(meters, units: units).split(/\s+/).last
  end

  private

  def formatted_distance(distance, units, precision)
    number_to_human(distance, units: units, precision: precision,
                    strip_insignificant_zeros: true, significant: false, delimiter: ',')
  end

  def determine_precision(distance)
    case distance
    when 0...10000
      2
    when 10000...1000000
      1
    else
      0
    end
  end

  def imperial_conversion(meters)
    miles = meters_to_miles(meters)
    yards = meters_to_yards(meters)

    if yards < 1760
      [yards, { unit: 'yard'.pluralize(yards) }]
    else
      [miles, { unit: 'mile'.pluralize(miles) }]
    end
  end

  def meters_to_miles(meters)
    meters * 0.000621371
  end

  def meters_to_yards(meters)
    meters * 1.09361
  end
end
