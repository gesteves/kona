require 'httparty'
require 'active_support/all'
require 'ostruct'
require_relative '../helpers/location_helpers'

# Class to interact with the Intervals.icu API to fetch and save athlete activity statistics.
class Intervals
  include LocationHelpers

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

  # Updates the athlete's weather forecast configuration on Intervals.icu by
  # merging forecasts for the current location and upcoming races within the
  # next 7 days into the existing config. Existing entries with matching labels
  # are preserved as-is, and the request is skipped if nothing would change.
  # @see https://intervals.icu/api-docs.html
  def update_weather_config
    existing = fetch_weather_config
    return if existing.nil?

    existing_labels = existing.map { |entry| entry['label'] }
    additions = build_forecasts.reject { |forecast| existing_labels.include?(forecast[:label]) }
    return if additions.empty?

    merged = existing + additions.map(&:stringify_keys)
    merged.each_with_index { |entry, index| entry['id'] = index }

    HTTParty.put(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config",
      body: { forecasts: merged }.to_json,
      headers: { 'Content-Type' => 'application/json' },
      basic_auth: { username: 'API_KEY', password: @api_key }
    )
  end

  private

  # Fetches the athlete's current weather forecast configuration from Intervals.icu.
  # @return [Array<Hash>, nil] The existing forecast entries, or nil on failure.
  def fetch_weather_config
    response = HTTParty.get(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config",
      basic_auth: { username: 'API_KEY', password: @api_key }
    )
    return nil unless response.success?

    body = JSON.parse(response.body)
    body.is_a?(Hash) ? (body['forecasts'] || []) : Array(body)
  end

  # Builds the array of forecast entries for the weather config from the
  # current location and any upcoming races within the next 7 days.
  # Entries are deduplicated by label, with races taking precedence over the
  # current location.
  # @return [Array<Hash>] Forecast entries with sequential ids.
  def build_forecasts
    races = upcoming_race_forecasts.uniq { |race| race[:label] }
    current = current_location_forecast

    entries = []
    entries << current if current && races.none? { |race| race[:label] == current[:label] }
    entries.concat(races)

    entries.each_with_index.map do |entry, index|
      entry.merge(id: index, provider: 'OPEN_WEATHER', enabled: true)
    end
  end

  # Builds a forecast entry from data/location.json.
  # @return [Hash, nil] The forecast entry, or nil if the file or required fields are missing.
  def current_location_forecast
    return nil unless File.exist?('data/location.json')

    location = deep_open_struct(JSON.parse(File.read('data/location.json')))
    formatted_address = location.geocoded&.formatted_address
    coords = location.geocoded&.geometry&.location
    return nil if formatted_address.blank? || coords.blank?

    {
      location: formatted_address,
      label: format_location(location).presence || formatted_address,
      lat: coords.lat,
      lon: coords.lng
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

      location = deep_open_struct(event['location'])
      {
        location: formatted_address,
        label: format_location(location).presence || formatted_address,
        lat: coords['lat'],
        lon: coords['lon']
      }
    end.compact
  end

  # Recursively converts a Hash into an OpenStruct so it supports the dot-access
  # that the LocationHelpers module expects.
  # @param obj [Object] The object to convert.
  # @return [Object] An OpenStruct, Array of converted values, or the original object.
  def deep_open_struct(obj)
    case obj
    when Hash
      OpenStruct.new(obj.transform_values { |v| deep_open_struct(v) })
    when Array
      obj.map { |v| deep_open_struct(v) }
    else
      obj
    end
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
