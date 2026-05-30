module BayHelper
  # Approximate flood-current set at SFB1204 (flows into the bay, roughly ESE).
  BAY_FLOOD_BEARING_DEG = 110
  # Below this current speed (knots) the current is treated as slack.
  BAY_SLACK_CURRENT_KT = 0.15

  # Finds the Goodspeed timeseries entry closest to the given time (within `freshness`).
  # @return [OpenStruct, nil]
  def bay_conditions_at(time, freshness: 30.minutes)
    series = @goodspeed&.timeseries
    return nil if series.blank?

    target = time.to_time
    closest = series.min_by { |e| (Time.parse(e.t) - target).abs }
    return nil if closest.blank?
    return nil if (Time.parse(closest.t) - target).abs > freshness.to_i

    closest
  end

  # Classifies the bay current as :slack, :flood, or :ebb.
  def bay_current_state(entry)
    return :slack if entry.current_speed_kt < BAY_SLACK_CURRENT_KT
    delta = (entry.current_bearing_deg - BAY_FLOOD_BEARING_DEG).abs % 360
    delta = 360 - delta if delta > 180
    delta <= 90 ? :flood : :ebb
  end

  # Formats the bay current speed (m/s → km/h) reusing the wind-speed metric/imperial toggle.
  def format_bay_current_speed(speed_ms)
    format_wind_speed(speed_ms * 3.6)
  end

  # Sentence describing the current SF Bay water temperature, for weather_summary.
  # @return [String, nil] nil unless the current location is SF and a recent entry exists.
  def bay_water_temperature_sentence
    return nil unless in_san_francisco?
    entry = bay_conditions_at(Time.now)
    return nil if entry.blank?
    "The water temperature in San Francisco Bay is #{format_temperature(entry.water_temp_c)}"
  end
end
