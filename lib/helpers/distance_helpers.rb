module DistanceHelpers

  DISTANCE_UNITS = {
    unit: 'meters',
    thousand: 'kilometers'
  }

  def format_distance(meters)
    precision = if meters < 10000
      2
    elsif meters < 1000000
      1
    else
      0
    end
    number_to_human(meters, units: DISTANCE_UNITS, precision: precision, strip_insignificant_zeros: true, significant: false, delimiter: ',')
  end

  def format_distance_number(meters)
    format_distance(meters).split(/\s+/).first
  end

  def format_distance_unit(meters)
    format_distance(meters).split(/\s+/).last
  end
end
