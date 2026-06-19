# Interacts with the Intervals.icu API to fetch and summarize the athlete's activity
# stats for the past month. The raw API response is cached in Redis for 5 minutes.
class Intervals < ApplicationService
  INTERVALS_ICU_API_URL = "https://intervals.icu/api/v1"

  # Maps each summarized distance bucket to the Intervals.icu activity types that feed it.
  SPORT_TYPES = {
    swim_distance: %w[Swim OpenWaterSwim],
    bike_distance: %w[Ride VirtualRide],
    run_distance:  %w[Run VirtualRun]
  }.freeze

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

  # Fetches activities from the Intervals.icu API for the past month, caching them in Redis
  # for 5 minutes. Uses string keys (symbolize: false), as the summary reads a["type"] etc.
  # @return [Array<Hash>, nil] List of activities, or nil on failure.
  def fetch_activities
    cached_json("intervals.icu:stats:#{@athlete_id}", expires_in: 5.minutes, symbolize: false) do
      newest = Date.today.to_s
      oldest = 1.month.ago.to_date.to_s

      get_json(
        "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/activities",
        symbolize: false,
        query: { oldest: oldest, newest: newest },
        basic_auth: { username: "API_KEY", password: @api_key }
      )
    end
  end

  # Summarizes activities into swim_distance, bike_distance, run_distance, and total_activities.
  # @param activities [Array<Hash>] List of activities.
  # @return [Hash] Summarized activity statistics.
  def summarize_activities(activities)
    distances = Hash.new(0)
    total_activities = 0

    activities.each do |a|
      bucket, = SPORT_TYPES.find { |_, types| types.include?(a["type"]) }
      next unless bucket

      distances[bucket] += a["distance"] || 0
      total_activities += 1
    end

    {
      swim_distance: distances[:swim_distance],
      bike_distance: distances[:bike_distance],
      run_distance: distances[:run_distance],
      total_activities: total_activities
    }
  end
end
