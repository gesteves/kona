# Reads and writes the athlete's Intervals.icu data: activity stats, profile and location,
# wellness records, and activity descriptions.
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

  # @return [Hash, nil] The past month's swim_distance, bike_distance, run_distance, and
  #   total_activities, or nil when the activities couldn't be fetched.
  def stats
    activities = fetch_activities
    return if activities.nil?

    summarize_activities(activities)
  end

  # The athlete's IANA timezone, cached for an hour. Falls back to UTC on any error; the
  # failure isn't cached, so the next call retries.
  # @return [String]
  def athlete_timezone
    cached_json("intervals.icu:timezone:#{@athlete_id}", expires_in: 1.hour) do
      get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/profile", basic_auth: auth)&.dig(:athlete, :timezone) || "UTC"
    end
  rescue StandardError => e
    Rails.logger.warn("Intervals: failed to fetch athlete timezone, falling back to UTC: #{e.message}")
    "UTC"
  end

  # The athlete's preferred temperature unit, cached for an hour. An explicit fahrenheit flag
  # wins; otherwise metric athletes get celsius.
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

  # Fetches the raw activity list for an inclusive date range. Uncached, since the caller is
  # matching against a just-finished workout.
  # @param oldest [Date, String] The range's start.
  # @param newest [Date, String] The range's end.
  # @return [Array<Hash>]
  # @raise [ApplicationService::HttpError] on failure, so the job retries.
  def activities!(oldest:, newest:)
    get_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/activities",
      query: { oldest: oldest.to_s, newest: newest.to_s },
      basic_auth: auth
    )
  end

  # @return [Hash] One raw activity.
  # @raise [ApplicationService::HttpError] on failure.
  def activity!(activity_id)
    activity = get_json!("#{INTERVALS_ICU_API_URL}/activity/#{activity_id}", basic_auth: auth)
    activity[:id] ||= activity_id
    activity
  end

  # @return [String, nil] The activity's weather summary with Intervals.icu's attribution
  #   prefix stripped, or nil — weather isn't available for every activity.
  def activity_weather_summary(activity_id)
    response = get_json!("#{INTERVALS_ICU_API_URL}/activity/#{activity_id}/weather-summary", basic_auth: auth)
    response&.dig(:description)&.sub(/\A-- Intervals icu --\n/i, "")&.strip.presence
  rescue StandardError
    nil
  end

  # Fetches activity streams by type. The query string is built by hand because Intervals.icu
  # expects repeated bare `types` params, which HTTParty would render as `types[]`.
  # @param types [Array<String>] The stream types to fetch.
  # @return [Array<Hash>, nil] { type:, data: } objects, or nil — not every activity has them.
  def activity_streams(activity_id, types:)
    query_string = types.map { |type| "types=#{type}" }.join("&")
    get_json!("#{INTERVALS_ICU_API_URL}/activity/#{activity_id}/streams?#{query_string}", basic_auth: auth)
  rescue StandardError
    nil
  end

  # A date's wellness record. Keys are not underscored — custom fields are CamelCase.
  # @param date [Date, String] The date, as YYYY-MM-DD.
  # @return [Hash, nil] The record, or nil on any error, since its only caller must never fail
  #   description generation.
  def wellness(date)
    get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/wellness/#{date}", basic_auth: auth)
  rescue StandardError
    nil
  end

  # Partially updates a date's wellness record; only the given fields change.
  # @param date [Date, String] The record's id, as YYYY-MM-DD.
  # @param fields [Hash] The fields to set.
  # @raise [ApplicationService::HttpError] on failure; a 422 means a missing custom field.
  def update_wellness!(date, fields)
    put_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/wellness/#{date}",
      body: fields.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # Partially updates an activity; only the given fields change.
  # @param fields [Hash] The fields to set.
  # @raise [ApplicationService::HttpError] on failure; a 422 means a missing custom field.
  def update_activity!(activity_id, fields)
    put_json!(
      "#{INTERVALS_ICU_API_URL}/activity/#{activity_id}",
      body: fields.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # The athlete's profile, read fresh — the location sync reads it to decide whether a write
  # is needed, so it must not be cached.
  # @return [Hash]
  # @raise [ApplicationService::HttpError] on failure, so the sync job retries.
  def athlete_profile
    get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}", basic_auth: auth)
  end

  # Updates the athlete's profile location. Only non-nil fields are sent, so a partial update
  # never clears one that wasn't resolved.
  # @raise [ApplicationService::HttpError] on failure.
  def update_athlete_profile(city: nil, state: nil, country: nil, timezone: nil)
    fields = { city: city, state: state, country: country, timezone: timezone }.compact
    put_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}",
      body: fields.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # The athlete's configured weather-forecast locations, read fresh for the location sync's
  # read-before-write comparison.
  # @return [Array<Hash>] The locations, empty when none are configured.
  # @raise [ApplicationService::HttpError] on failure.
  def weather_config
    response = get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config", basic_auth: auth)
    response&.dig(:forecasts) || []
  end

  # Replaces the athlete's weather-forecast locations.
  # @param forecasts [Array<Hash>] The locations to set.
  # @raise [ApplicationService::HttpError] on failure.
  def update_weather_config(forecasts)
    put_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config",
      body: { forecasts: forecasts }.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # Overwrites the cached athlete timezone, so a just-PUT value is reflected immediately rather
  # than after the TTL expires. Mirrors athlete_timezone's own storage so it round-trips
  # through cached_json. No-op in development, where the cache is bypassed.
  # @param timezone [String] An IANA timezone id.
  def cache_athlete_timezone(timezone)
    return if Rails.env.development?

    $redis.setex("intervals.icu:timezone:#{@athlete_id}", 1.hour.to_i, timezone.to_json)
  end

  private

  # HTTP Basic credentials: the username is the literal "API_KEY", the password is the key.
  def auth
    { username: "API_KEY", password: @api_key }
  end

  # The past month's activities, cached for 5 minutes. String-keyed, as the summary reads
  # a["type"].
  # @return [Array<Hash>, nil] The activities, or nil on failure.
  def fetch_activities
    cached_json("intervals.icu:stats:#{@athlete_id}", expires_in: 5.minutes, symbolize: false) do
      # In the athlete's zone, not the server's, or the window's edges shift by a day.
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

  # @param activities [Array<Hash>] The activities to summarize.
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
