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

  # Updates the athlete's weather forecast configuration on Intervals.icu
  # using the current location and upcoming races within the next 7 days.
  # @see https://intervals.icu/api-docs.html
  def update_weather_config
    forecasts = build_forecasts
    return if forecasts.blank?

    HTTParty.put(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config",
      body: { forecasts: forecasts }.to_json,
      headers: { 'Content-Type' => 'application/json' },
      basic_auth: { username: 'API_KEY', password: @api_key }
    )
  end

  private

  # Builds the array of forecast entries for the weather config from the
  # current location and any upcoming races within the next 7 days.
  # @return [Array<Hash>] Forecast entries with sequential ids.
  def build_forecasts
    entries = [current_location_forecast, *upcoming_race_forecasts].compact
    entries.each_with_index.map do |entry, index|
      entry.merge(id: index, provider: 'OPEN_WEATHER', enabled: true)
    end
  end

  # Builds a forecast entry from data/location.json.
  # @return [Hash, nil] The forecast entry, or nil if the file or required fields are missing.
  def current_location_forecast
    return nil unless File.exist?('data/location.json')

    data = JSON.parse(File.read('data/location.json'))
    formatted_address = data.dig('geocoded', 'formatted_address')
    coords = data.dig('geocoded', 'geometry', 'location')
    return nil if formatted_address.blank? || coords.blank?

    {
      location: formatted_address,
      label: formatted_address,
      lat: coords['lat'],
      lon: coords['lng']
    }
  end

  # Builds forecast entries for races in data/events.json that are within the
  # next 7 days and the athlete is going to.
  # @return [Array<Hash>] The forecast entries.
  def upcoming_race_forecasts
    return [] unless File.exist?('data/events.json')

    events = JSON.parse(File.read('data/events.json'))
    cutoff = 7.days.from_now
    now = Time.now

    events.select do |event|
      next false unless event['going'] == true
      next false if event['date'].blank?

      date = Time.parse(event['date'])
      date >= now && date <= cutoff
    end.map do |event|
      formatted_address = event.dig('location', 'geocoded', 'formatted_address')
      coords = event['coordinates']
      next nil if formatted_address.blank? || coords.blank?

      {
        location: formatted_address,
        label: formatted_address,
        lat: coords['lat'],
        lon: coords['lon']
      }
    end.compact
  end

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
