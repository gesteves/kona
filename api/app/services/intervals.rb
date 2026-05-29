require "httparty"

# Interacts with the Intervals.icu API to fetch and summarize the athlete's activity
# stats for the past month. The raw API response is cached in Redis for 5 minutes.
class Intervals
  INTERVALS_ICU_API_URL = "https://intervals.icu/api/v1"

  def initialize
    @athlete_id = ENV["ICU_ATHLETE_ID"]
    @api_key = ENV["ICU_API_KEY"]
  end

  # Returns summarized activity stats for the past month.
  # @return [Hash, nil] A hash with swim_distance, bike_distance, run_distance, and
  #   total_activities, or nil if the activities couldn't be fetched.
  def stats
    activities = fetch_activities
    return if activities.nil?

    summarize_activities(activities)
  end

  private

  # Fetches activities from the Intervals.icu API for the past month, caching the raw
  # response body in Redis for 5 minutes.
  # @return [Array<Hash>, nil] List of activities, or nil on failure.
  def fetch_activities
    cache_key = "intervals.icu:stats:#{@athlete_id}"
    data = $redis.get(cache_key)
    return JSON.parse(data) if data.present?

    newest = Date.today.to_s
    oldest = 1.month.ago.to_date.to_s

    response = HTTParty.get(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/activities",
      query: { oldest: oldest, newest: newest },
      basic_auth: { username: "API_KEY", password: @api_key }
    )

    return unless response.success?

    $redis.setex(cache_key, 5.minutes, response.body)
    JSON.parse(response.body)
  end

  # Summarizes activities into swim_distance, bike_distance, run_distance, and total_activities.
  # @param activities [Array<Hash>] List of activities.
  # @return [Hash] Summarized activity statistics.
  def summarize_activities(activities)
    swim_distance = activities.select { |a| ["Swim", "OpenWaterSwim"].include?(a["type"]) }.sum { |a| a["distance"] || 0 }
    bike_distance = activities.select { |a| ["Ride", "VirtualRide"].include?(a["type"]) }.sum { |a| a["distance"] || 0 }
    run_distance = activities.select { |a| ["Run", "VirtualRun"].include?(a["type"]) }.sum { |a| a["distance"] || 0 }
    total_activities = activities.count { |a| ["Swim", "OpenWaterSwim", "Ride", "VirtualRide", "Run", "VirtualRun"].include?(a["type"]) }

    {
      swim_distance: swim_distance,
      bike_distance: bike_distance,
      run_distance: run_distance,
      total_activities: total_activities
    }
  end
end
