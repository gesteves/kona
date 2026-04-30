require 'httparty'
require 'active_support/all'
require 'ostruct'
require_relative 'location'
require_relative 'google_maps'
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

  # Overwrites the athlete's weather forecast configuration on Intervals.icu
  # with a single forecast entry for the current location. Skipped when the
  # existing config already matches by lat/lon.
  # @see https://intervals.icu/api-docs.html
  def update_weather_config
    new_forecasts = build_forecasts
    return if new_forecasts.blank?

    existing = fetch_weather_config
    return if existing.nil?
    return if forecasts_equal?(existing, new_forecasts)

    HTTParty.put(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config",
      body: { forecasts: new_forecasts }.to_json,
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

  # Compares two lists of forecasts by label, ignoring order. We can't compare
  # lat/lon because Intervals.icu truncates them when saving.
  # @param existing [Array<Hash>] Forecasts returned from the API (string keys).
  # @param new_forecasts [Array<Hash>] Forecasts we'd send (symbol keys).
  # @return [Boolean] True if the two lists have the same set of labels.
  def forecasts_equal?(existing, new_forecasts)
    existing.map { |entry| entry['label'] }.sort == new_forecasts.map { |entry| entry[:label] }.sort
  end

  # Builds a single-entry forecast list for the current location, sourced from
  # the Location class so we get the raw coordinates rather than the geocoded
  # ones in data/location.json. The label comes from format_location applied
  # to GoogleMaps' reverse-geocoded data.
  # @return [Array<Hash>] The forecast entries.
  def build_forecasts
    raw_location = Location.new
    return [] if raw_location.latitude.blank? || raw_location.longitude.blank?

    google_maps = GoogleMaps.new(raw_location.latitude, raw_location.longitude)
    location_struct = deep_open_struct(google_maps.location)
    label = format_location(location_struct).presence ||
      location_struct.geocoded&.formatted_address.presence ||
      'Current location'

    [{
      id: 0,
      provider: 'OPEN_WEATHER',
      location: label,
      label: label,
      lat: google_maps.latitude,
      lon: google_maps.longitude,
      enabled: true
    }]
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
