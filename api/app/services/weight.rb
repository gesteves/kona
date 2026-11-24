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
  #
  # ⚠️ A day in the future is incorrect. .save sends each day from today on to Strava, which keeps
  # one current weight, thus a typing error in the year would replace that weight. Tomorrow is
  # permitted: the caller can be in a time zone that is ahead of the stored location.
  # @param value [String, nil] An ISO 8601 date. When it is blank, the day is today in the time zone
  #   of the current location.
  # @return [Date, nil] The day, or nil if the value is incorrect or after tomorrow.
  def self.parse_date(value)
    return today if value.blank?

    date = Date.iso8601(value.to_s)
    date unless date > today + 1
  rescue Date::Error
    nil
  end

  # @return [Date] Today in the time zone of the current location.
  def self.today
    Time.current.in_time_zone(Location.new.time_zone).to_date
  end

  # Adds the sync jobs.
  #
  # ⚠️ The caller gives the day, and each job gets it as a string. A retry after midnight must not
  # move the weight to the next day.
  # ⚠️ Strava keeps one current weight and no history. Thus a weight for a past day goes to
  # Intervals.icu only, or it would replace the current weight on Strava.
  def self.save(kg, date)
    IntervalsWeightJob.perform_async(kg, date.iso8601)
    StravaWeightJob.perform_async(kg) if date >= today
  end
end
