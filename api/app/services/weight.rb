# A body weight from POST /api/weight. It parses the input and adds one job for each destination:
# the wellness record of Intervals.icu and the profile of the athlete on Strava.
class Weight
  POUNDS_TO_KG = 0.45359237
  UNITS = %w[kg lb].freeze
  # The range of a correct weight in kilograms. A value outside it is a typing error.
  RANGE_KG = (20.0..300.0)

  # Parses a weight and converts it to kilograms.
  #
  # ⚠️ It parses with Float(), and not with to_f. to_f changes text that it cannot parse into 0.0.
  # @param value [String, Numeric, nil] The weight.
  # @param unit [String, nil] "kg" or "lb". The default is "kg".
  # @return [Float, nil] The weight in kilograms, or nil if the value or the unit is incorrect.
  def self.parse(value, unit = nil)
    unit = unit.presence&.downcase || "kg"
    return unless UNITS.include?(unit)

    weight = Float(value, exception: false)
    return if weight.nil?

    kg = (unit == "lb" ? weight * POUNDS_TO_KG : weight).round(2)
    kg if RANGE_KG.cover?(kg)
  end

  # Parses the day of the weight.
  # @param value [String, nil] An ISO 8601 date. When it is blank, the day is today in the time zone
  #   of the current location.
  # @return [Date, nil] The day, or nil if the value is incorrect.
  def self.parse_date(value)
    return Time.current.in_time_zone(Location.new.time_zone).to_date if value.blank?

    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end

  # Adds the two sync jobs.
  #
  # ⚠️ The caller gives the day, and each job gets it as a string. A retry after midnight must not
  # move the weight to the next day.
  # @param kg [Float] The weight in kilograms.
  # @param date [Date] The day of the weight.
  def self.save(kg, date)
    IntervalsWeightJob.perform_async(kg, date.iso8601)
    StravaWeightJob.perform_async(kg)
  end
end
