module DistanceHelpers

  DISTANCE_UNITS = {
    unit: 'meters',
    thousand: 'kilometers'
  }

  def format_distance(meters, units: 'si')
    case units
    when 'si', 'metric'
      precision = if meters < 10000
        2
      elsif meters < 1000000
        1
      else
        0
      end
      number_to_human(meters, units: DISTANCE_UNITS, precision: precision, strip_insignificant_zeros: true, significant: false, delimiter: ',')
    when 'imperial'
      miles = meters_to_miles(meters)
      yards = meters_to_yards(meters)
      if yards < 1000
        distance = yards
        units = { unit: "yards" }
      else
        distance = miles
        units = { unit: "miles" }
      end
      precision = if distance < 10
        2
      elsif distance < 1000
        1
      else
        0
      end
      number_to_human(distance, units: units, precision: precision, strip_insignificant_zeros: true, significant: false, delimiter: ',')
    end
  end

  def format_distance_number(meters, units: 'si')
    format_distance(meters, units: units).split(/\s+/).first
  end

  def format_distance_unit(meters, units: 'si')
    format_distance(meters, units: units).split(/\s+/).last
  end

  def meters_to_miles(meters)
    miles = meters * 0.000621371
  end

  def meters_to_yards(meters)
    meters * 1.09361
  end
end
