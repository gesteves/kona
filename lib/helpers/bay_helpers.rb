require 'active_support/all'

# Helpers for displaying San Francisco Bay conditions sourced from the
# Goodspeed feed (NOAA SFBOFS model at station SFB1204, SW of Alcatraz).
module BayHelpers
  # Approximate flood-current set at SFB1204. Flood flows into the bay
  # (roughly ESE); ebb flows out toward the Golden Gate. Mirrors Goodspeed's
  # FLOOD_BEARING_DEG constant.
  BAY_FLOOD_BEARING_DEG = 110

  # Below this current speed (in knots) the current is treated as slack.
  # Mirrors Goodspeed's SLACK_CURRENT_KT constant.
  BAY_SLACK_CURRENT_KT = 0.15

  # Finds the timeseries entry closest to the given time.
  # @param time [Time] The target time (any time zone; compared as an absolute moment).
  # @param freshness [ActiveSupport::Duration] Maximum allowed distance between the
  #   target time and the closest entry. Returns nil if the closest entry is further
  #   away than this.
  # @return [Hash, nil] The closest timeseries entry, or nil when the data is missing,
  #   empty, or stale.
  def bay_conditions_at(time, freshness: 30.minutes)
    series = data.goodspeed&.timeseries
    return nil if series.blank?

    target = time.to_time
    closest = series.min_by { |e| (Time.parse(e.t) - target).abs }
    return nil if closest.blank?
    return nil if (Time.parse(closest.t) - target).abs > freshness.to_i

    closest
  end

  # Classifies the bay current using the same algorithm as the Goodspeed dashboard.
  # @param entry [Hash] A timeseries entry.
  # @return [Symbol] :slack, :flood, or :ebb.
  def bay_current_state(entry)
    return :slack if entry.current_speed_kt < BAY_SLACK_CURRENT_KT
    delta = (entry.current_bearing_deg - BAY_FLOOD_BEARING_DEG).abs % 360
    delta = 360 - delta if delta > 180
    delta <= 90 ? :flood : :ebb
  end

  # Formats the bay current speed by reusing format_wind_speed so the metric/imperial
  # toggle (km/h ↔ mph) matches the rest of the weather UI.
  # @param speed_ms [Float] Speed in meters per second.
  # @return [String] HTML tag with the formatted speed.
  def format_bay_current_speed(speed_ms)
    format_wind_speed(speed_ms * 3.6)
  end

  # Sentence describing the current water temperature in San Francisco Bay,
  # for use inside weather_summary.
  # @return [String, nil] Returns nil unless the current location is SF and a
  #   recent entry is available.
  def bay_water_temperature_sentence
    return nil unless in_san_francisco?
    entry = bay_conditions_at(Time.now)
    return nil if entry.blank?
    "The water temperature in San Francisco Bay is #{format_temperature(entry.water_temp_c)}"
  end
end
