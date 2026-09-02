module BayHelper
  # The approximate direction of the flood current at SFB1204. It goes into the bay, at
  # approximately ESE.
  BAY_FLOOD_BEARING_DEG = 110
  # Below this speed in knots, the code counts the current as slack.
  BAY_SLACK_CURRENT_KT = 0.15

  # Finds the Goodspeed entry that is nearest to the given time, in the `freshness` window.
  # @param goodspeed [OpenStruct, nil] The Goodspeed bay-conditions data.
  # @return [OpenStruct, nil]
  def bay_conditions_at(goodspeed, time, freshness: 30.minutes)
    series = goodspeed&.timeseries
    return nil if series.blank?

    target = time.to_time
    closest = series.min_by { |e| (Time.parse(e.t) - target).abs }
    return nil if closest.blank?
    return nil if (Time.parse(closest.t) - target).abs > freshness.to_i

    closest
  end

  # Formats the speed of the bay current, from m/s into km/h. It uses the metric and imperial
  # control of the wind speed.
  def format_bay_current_speed(speed_ms)
    format_wind_speed(speed_ms * 3.6)
  end

  # A sentence about the current water temperature of San Francisco Bay, for weather_summary.
  # @param goodspeed [OpenStruct, nil] The Goodspeed bay-conditions data.
  # @param location [OpenStruct, nil] The current location, from a GoogleMaps result.
  # @return [String, nil] It is nil if the location is not San Francisco, and if there is no recent
  #   entry.
  def bay_water_temperature_sentence(goodspeed, location)
    return nil unless in_san_francisco?(location)
    entry = bay_conditions_at(goodspeed, Time.now)
    return nil if entry.blank?
    "The water temperature in San Francisco Bay is #{format_temperature(entry.water_temp_c)}"
  end
end
