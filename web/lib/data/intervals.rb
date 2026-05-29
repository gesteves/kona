require 'httparty'
require 'active_support/all'

# Class to interact with the Intervals.icu API to fetch and save athlete activity statistics.
class Intervals
  INTERVALS_ICU_API_URL = 'https://intervals.icu/api/v1'

  def initialize
    @athlete_id = ENV['ICU_ATHLETE_ID']
    @api_key = ENV['ICU_API_KEY']
  end

  # Fetches and saves the activity stats for the past month to a JSON file.
  def save_data
    activities = fetch_activities
    stats = summarize_activities(activities)

    File.open('data/intervals.json', 'w') do |f|
      f << stats.to_json
    end
  end

  private

  # Fetch activities from the Intervals.icu API for the past month.
  # @return [Array<Hash>] List of activities.
  def fetch_activities
    cache_key = "intervals.icu:stats:#{@athlete_id}"
    data = $redis.get(cache_key)

    return JSON.parse(data) if data.present?

    newest = Date.today.to_s
    oldest = 1.month.ago.to_date.to_s

    response = HTTParty.get(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/activities",
      query: { oldest: oldest, newest: newest },
      basic_auth: { username: 'API_KEY', password: @api_key }
    )

    return unless response.success?

    $redis.setex(cache_key, 1.minute, response.body)
    JSON.parse(response.body)
  end

  # Summarize activities to include swim_distance, bike_distance, run_distance, and total_activities.
  # @param activities [Array<Hash>] List of activities.
  # @return [Hash] Summarized activity statistics.
  def summarize_activities(activities)
    swim_distance = activities.select { |a| ['Swim', 'OpenWaterSwim'].include?(a['type']) }.sum { |a| a['distance'] || 0 }
    bike_distance = activities.select { |a| ['Ride', 'VirtualRide'].include?(a['type']) }.sum { |a| a['distance'] || 0 }
    run_distance = activities.select { |a| ['Run', 'VirtualRun'].include?(a['type']) }.sum { |a| a['distance'] || 0 }
    total_activities = activities.count { |a| ['Swim', 'OpenWaterSwim', 'Ride', 'VirtualRide', 'Run', 'VirtualRun'].include?(a['type']) }

    {
      swim_distance: swim_distance,
      bike_distance: bike_distance,
      run_distance: run_distance,
      total_activities: total_activities
    }
  end
end
