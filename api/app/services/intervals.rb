# Reads and writes the Intervals.icu data of the athlete: the activity stats, the profile and the
# location, the wellness records, and the activity descriptions.
class Intervals < ApplicationService
  INTERVALS_ICU_API_URL = "https://intervals.icu/api/v1"

  # Gives the Intervals.icu activity types for each group of distances in the summary.
  SPORT_TYPES = {
    swim_distance: %w[Swim OpenWaterSwim],
    bike_distance: %w[Ride VirtualRide],
    run_distance:  %w[Run VirtualRun]
  }.freeze

  def initialize
    @athlete_id = ENV["ICU_ATHLETE_ID"]
    @api_key = ENV["ICU_API_KEY"]
  end

  # @return [Hash, nil] The swim_distance, the bike_distance, the run_distance, and the
  #   total_activities of the last month, or nil if the code cannot get the activities.
  def stats
    activities = fetch_activities
    return if activities.nil?

    summarize_activities(activities)
  end

  # The IANA timezone of the athlete. The cache holds it for an hour. On an error it gives UTC.
  # The cache does not hold a failure, thus the next call tries again.
  # @return [String]
  def athlete_timezone
    cached_json("intervals.icu:timezone:#{@athlete_id}", expires_in: 1.hour) do
      get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/profile", basic_auth: auth)&.dig(:athlete, :timezone) || "UTC"
    end
  rescue StandardError => e
    Rails.logger.warn("Intervals: failed to fetch athlete timezone, falling back to UTC: #{e.message}")
    "UTC"
  end

  # The temperature unit that the athlete prefers. The cache holds it for an hour. A fahrenheit
  # flag has the highest importance. In all other conditions a metric athlete gets celsius.
  # @return [Symbol] :celsius or :fahrenheit.
  def temperature_unit
    cached = cached_json("intervals.icu:temperature_unit:#{@athlete_id}", expires_in: 1.hour) do
      athlete = get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}", basic_auth: auth)
      if athlete[:fahrenheit] || athlete[:measurement_preference] == "feet"
        "fahrenheit"
      else
        "celsius"
      end
    end
    cached.to_sym
  rescue StandardError => e
    Rails.logger.warn("Intervals: failed to fetch temperature unit, falling back to celsius: #{e.message}")
    :celsius
  end

  # Gets the raw activity list for a date range, and the range includes both dates. No cache
  # holds it, because the caller compares it with a workout that just ended.
  # @param oldest [Date, String] The start of the range.
  # @param newest [Date, String] The end of the range.
  # @return [Array<Hash>]
  # @raise [ApplicationService::HttpError] If it fails, thus the job runs again.
  def activities!(oldest:, newest:)
    get_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/activities",
      query: { oldest: oldest.to_s, newest: newest.to_s },
      basic_auth: auth
    )
  end

  # @return [Hash] One raw activity.
  # @raise [ApplicationService::HttpError] If it fails.
  def activity!(activity_id)
    activity = get_json!("#{INTERVALS_ICU_API_URL}/activity/#{activity_id}", basic_auth: auth)
    activity[:id] ||= activity_id
    activity
  end

  # @return [String, nil] The weather summary of the activity, with the Intervals.icu attribution
  #   text removed from the start, or nil. Not each activity has weather data.
  def activity_weather_summary(activity_id)
    safely("Intervals.icu", context: "activity_weather_summary") do
      response = get_json!("#{INTERVALS_ICU_API_URL}/activity/#{activity_id}/weather-summary", basic_auth: auth)
      response&.dig(:description)&.sub(/\A-- Intervals icu --\n/i, "")&.strip.presence
    end
  end

  # Gets the activity streams by type. The code makes the query string itself, because
  # Intervals.icu needs more than one plain `types` parameter, and HTTParty would write `types[]`.
  # @param types [Array<String>] The stream types to get.
  # @return [Array<Hash>, nil] The { type:, data: } objects, or nil. Not each activity has them.
  def activity_streams(activity_id, types:)
    query_string = types.map { |type| "types=#{type}" }.join("&")
    safely("Intervals.icu", context: "activity_streams") do
      get_json!("#{INTERVALS_ICU_API_URL}/activity/#{activity_id}/streams?#{query_string}", basic_auth: auth)
    end
  end

  # The wellness record of a date. The keys have no underscores, because a custom field is
  # CamelCase.
  # @param date [Date, String] The date, as YYYY-MM-DD.
  # @return [Hash, nil] The record, or nil on an error, because its one caller must never stop the
  #   generation of a description.
  def wellness(date)
    safely("Intervals.icu", context: "wellness") do
      get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/wellness/#{date}", basic_auth: auth)
    end
  end

  # Updates part of the wellness record of a date. Only the given fields change.
  # @param date [Date, String] The id of the record, as YYYY-MM-DD.
  # @param fields [Hash] The fields to set.
  # @raise [ApplicationService::HttpError] If it fails. A 422 means that a custom field is absent.
  def update_wellness!(date, fields)
    put_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/wellness/#{date}",
      body: fields.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # Updates part of an activity. Only the given fields change.
  # @param fields [Hash] The fields to set.
  # @raise [ApplicationService::HttpError] If it fails. A 422 means that a custom field is absent.
  def update_activity!(activity_id, fields)
    put_json!(
      "#{INTERVALS_ICU_API_URL}/activity/#{activity_id}",
      body: fields.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # The profile of the athlete, read new each time. The location sync reads it to decide if a
  # write is necessary, thus no cache must hold it.
  # @return [Hash]
  # @raise [ApplicationService::HttpError] on failure, so the sync job retries.
  def athlete_profile
    get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}", basic_auth: auth)
  end

  # Updates the profile location of the athlete. It sends only the fields that are not nil, thus
  # an update of one part never removes a field that the code did not find.
  # @raise [ApplicationService::HttpError] If it fails.
  def update_athlete_profile(city: nil, state: nil, country: nil, timezone: nil)
    fields = { city: city, state: state, country: country, timezone: timezone }.compact
    put_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}",
      body: fields.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # The weather-forecast locations of the athlete, read new each time, for the read-before-write
  # comparison of the location sync.
  # @return [Array<Hash>] The locations. It is empty if there are none.
  # @raise [ApplicationService::HttpError] If it fails.
  def weather_config
    response = get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config", basic_auth: auth)
    response&.dig(:forecasts) || []
  end

  # Replaces the weather-forecast locations of the athlete.
  # @param forecasts [Array<Hash>] The locations to set.
  # @raise [ApplicationService::HttpError] If it fails.
  def update_weather_config(forecasts)
    put_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config",
      body: { forecasts: forecasts }.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # Replaces the athlete timezone in the cache, thus a value from a new PUT appears immediately
  # and not after the TTL ends. It writes the value in the same shape as athlete_timezone, thus
  # cached_json can read it. It does nothing in development, where the code does not use the
  # cache.
  # @param timezone [String] An IANA timezone id.
  def cache_athlete_timezone(timezone)
    return if Rails.env.development?

    $redis.setex("intervals.icu:timezone:#{@athlete_id}", 1.hour.to_i, timezone.to_json)
  end

  private

  # The HTTP Basic credentials: the user name is the text "API_KEY", and the password is the key.
  def auth
    { username: "API_KEY", password: @api_key }
  end

  # The activities of the last month. The cache holds them for 5 minutes. They have string keys,
  # because the summary reads a["type"].
  # @return [Array<Hash>, nil] The activities, or nil if it fails.
  def fetch_activities
    # The negative TTL is a delay: without it, an outage costs a full request on each page.
    cached_json("intervals.icu:stats:#{@athlete_id}", expires_in: 5.minutes, empty_expires_in: 1.minute, symbolize: false) do
      # Use the zone of the athlete, not the zone of the server. If you do not, the limits of the
      # window move by one day.
      today = Time.current.in_time_zone(athlete_timezone).to_date
      newest = today.to_s
      oldest = (today << 1).to_s

      get_json(
        "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/activities",
        symbolize: false,
        query: { oldest: oldest, newest: newest },
        basic_auth: auth
      )
    end
  end

  # @param activities [Array<Hash>] The activities for the summary.
  # @return [Hash] Their swim_distance, bike_distance, run_distance, and total_activities.
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
