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

  # The athlete's IANA timezone from the (nested) profile endpoint, cached for an hour.
  # Falls back to UTC on any error — the failure isn't cached, so the next call retries.
  # @return [String]
  def athlete_timezone
    cached_json("intervals.icu:timezone:#{@athlete_id}", expires_in: 1.hour) do
      get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/profile", basic_auth: auth)&.dig(:athlete, :timezone) || "UTC"
    end
  rescue StandardError => e
    Rails.logger.warn("Intervals: failed to fetch athlete timezone, falling back to UTC: #{e.message}")
    "UTC"
  end

  # The athlete's preferred temperature unit, derived from the root athlete endpoint the
  # same way domestique's unit preferences were: an explicit fahrenheit flag wins; otherwise
  # metric athletes (measurement_preference != "feet") get celsius. Cached for an hour.
  # @return [Symbol] :celsius or :fahrenheit
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

  # Fetches the raw activity list for a date range (inclusive), raising on failure so the
  # webhook job can retry. Uncached: the caller is matching against a just-finished workout.
  # @param oldest [Date, String]
  # @param newest [Date, String]
  # @return [Array<Hash>]
  # @raise [ApplicationService::HttpError]
  def activities!(oldest:, newest:)
    get_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/activities",
      query: { oldest: oldest.to_s, newest: newest.to_s },
      basic_auth: auth
    )
  end

  # Fetches a single raw activity, raising on failure.
  # @return [Hash]
  # @raise [ApplicationService::HttpError]
  def activity!(activity_id)
    activity = get_json!("#{INTERVALS_ICU_API_URL}/activity/#{activity_id}", basic_auth: auth)
    activity[:id] ||= activity_id
    activity
  end

  # The activity's weather summary text, with Intervals.icu's own attribution prefix
  # stripped. Any error → nil (weather isn't available for every activity).
  # @return [String, nil]
  def activity_weather_summary(activity_id)
    response = get_json!("#{INTERVALS_ICU_API_URL}/activity/#{activity_id}/weather-summary", basic_auth: auth)
    response&.dig(:description)&.sub(/\A-- Intervals icu --\n/i, "")&.strip.presence
  rescue StandardError
    nil
  end

  # Fetches activity streams by type. Intervals.icu expects repeated bare `types` params
  # (types=a&types=b), which HTTParty would render as types[]= — so the query string is
  # built by hand. Any error → nil (streams aren't available for every activity).
  # @param types [Array<String>] e.g. ["heat_strain_index", "time"]
  # @return [Array<Hash>, nil] Stream objects ({type:, data: [...]}), or nil.
  def activity_streams(activity_id, types:)
    query_string = types.map { |type| "types=#{type}" }.join("&")
    get_json!("#{INTERVALS_ICU_API_URL}/activity/#{activity_id}/streams?#{query_string}", basic_auth: auth)
  rescue StandardError
    nil
  end

  # The wellness record for a date. Any error → nil (used for the optional
  # CoreHeatAdaptationScore, which must never fail description generation).
  # Keys are NOT underscored: custom fields like CoreHeatAdaptationScore are CamelCase.
  # @param date [Date, String] YYYY-MM-DD.
  # @return [Hash, nil]
  def wellness(date)
    get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/wellness/#{date}", basic_auth: auth)
  rescue StandardError
    nil
  end

  # Partially updates the wellness record for a date (only the provided fields change).
  # @param date [Date, String] YYYY-MM-DD (the wellness record's id).
  # @param fields [Hash] e.g. { WhoopStrain: 14.2 }.
  # @raise [ApplicationService::HttpError] on failure (422 = missing custom field).
  def update_wellness!(date, fields)
    put_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/wellness/#{date}",
      body: fields.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # Partially updates an activity (only the provided fields change).
  # @param fields [Hash] e.g. { WhoopWorkoutStrain: 12.4 } or { description: "..." }.
  # @raise [ApplicationService::HttpError] on failure (422 = missing custom field).
  def update_activity!(activity_id, fields)
    put_json!(
      "#{INTERVALS_ICU_API_URL}/activity/#{activity_id}",
      body: fields.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # The athlete's profile (city/state/country/timezone and more), read fresh — deliberately
  # uncached, since the location sync reads it to decide whether a write is needed. Raises on
  # failure so the sync job can retry.
  # @return [Hash]
  # @raise [ApplicationService::HttpError]
  def athlete_profile
    get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}", basic_auth: auth)
  end

  # Updates the athlete's profile location fields. Only the non-nil keys are sent, so a partial
  # update never clears a field that wasn't resolved. Raises on failure.
  # @raise [ApplicationService::HttpError]
  def update_athlete_profile(city: nil, state: nil, country: nil, timezone: nil)
    fields = { city: city, state: state, country: country, timezone: timezone }.compact
    put_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}",
      body: fields.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # The athlete's configured weather-forecast locations, read fresh (uncached) for the location
  # sync's read-before-write comparison. Raises on failure.
  # @return [Array<Hash>] The forecast locations (empty when none are configured).
  # @raise [ApplicationService::HttpError]
  def weather_config
    response = get_json!("#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config", basic_auth: auth)
    response&.dig(:forecasts) || []
  end

  # Replaces the athlete's weather-forecast locations. Raises on failure.
  # @param forecasts [Array<Hash>]
  # @raise [ApplicationService::HttpError]
  def update_weather_config(forecasts)
    put_json!(
      "#{INTERVALS_ICU_API_URL}/athlete/#{@athlete_id}/weather-config",
      body: { forecasts: forecasts }.to_json,
      headers: { "Content-Type" => "application/json" },
      basic_auth: auth
    )
  end

  # Primes (overwrites) the cached athlete timezone with a known-authoritative value — used by
  # the location sync right after it PUTs a new timezone, so athlete_timezone reflects it
  # immediately instead of serving the stale cached value until the 1-hour TTL expires. Mirrors
  # athlete_timezone's own storage (JSON-encoded value, 1-hour TTL) so it round-trips cleanly
  # through cached_json. No-op in development, where cached_json bypasses the cache entirely.
  # @param timezone [String] An IANA timezone id.
  def cache_athlete_timezone(timezone)
    return if Rails.env.development?

    $redis.setex("intervals.icu:timezone:#{@athlete_id}", 1.hour.to_i, timezone.to_json)
  end

  private

  # HTTP Basic credentials for every Intervals.icu call: the username is the literal
  # string "API_KEY", the password is the athlete's API key.
  def auth
    { username: "API_KEY", password: @api_key }
  end

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
