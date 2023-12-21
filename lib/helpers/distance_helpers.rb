module DistanceHelpers

  def distance(meters, units: 'si')
    case units
    when 'si', 'metric'
      metric_distance, metric_units = metric_conversion(meters)
      formatted_distance(metric_distance, metric_units, determine_precision(metric_distance))
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
    when 0...10
      2
    when 10...1000
      1
    else
      0
    end
  end

  def metric_conversion(meters)
    kilometers = meters / 1000.0

    if meters < 1000
      [meters, { unit: 'meter'.pluralize(meter) }]
    else
      [kilometers, { unit: 'kilometer'.pluralize(kilometers) }]
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
