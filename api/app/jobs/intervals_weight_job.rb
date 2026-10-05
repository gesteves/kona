# Writes a body weight to the wellness record of one day on Intervals.icu. Api::WeightController
# adds it to the queue. The PUT changes the weight field only, thus a retry is safe.
class IntervalsWeightJob < ApplicationJob
  # @param kg [Float] The weight in kilograms.
  # @param date [String] The ISO 8601 day of the wellness record.
  def perform(kg, date)
    Intervals.new.update_wellness!(date, weight: kg)
    Rails.logger.info("Weight synced to Intervals.icu (#{kg} kg on #{date})")
  end
end
