module ActivityDescription
  # Writes the weather line of an activity description from the summary of Weather, for example
  # "Cloudy with some rain · 11°C–13°C (feels like 8°C–10°C) · 12–18 km/h SSE wind with
  # 24 km/h gusts (62% headwind) · AQI 54". The emoji is not here: Weather#emoji gives it.
  #
  # ⚠️ This writes words and decides nothing. Weather already selected each part and rounded each
  # number, thus a change to what the line holds goes there. These are functions with no I/O.
  module WeatherSentence
    # A negative temperature takes a true minus sign, and not a hyphen.
    MINUS = "−".freeze

    module_function

    # The separator of the parts, the same as in the other stat lines.
    SEPARATOR = " · ".freeze

    # The parts, in this order: the conditions, the temperature, the humidity, the wind, and the AQI.
    # @param summary [Hash] The summary of Weather.
    # @param changing [String, nil] The phrase of the LLM from the condition facts. With nil,
    #   the line uses #conditions.
    # @return [String] The line, with no emoji and no period at the end.
    def call(summary, changing = nil)
      units = summary[:units] || {}
      [
        changing.presence || conditions(summary),
        temperature(summary, units[:temperature]),
        ("#{summary[:humidity_percent]}% humidity" if summary[:humidity_percent]),
        (wind(summary[:wind], summary[:headwind_percent], units[:wind]) if summary[:wind]),
        ("AQI #{summary[:aqi]}" if summary[:aqi])
      ].compact.join(SEPARATOR)
    end

    # "Cloudy", or "Cloudy with some rain" for precipitation during part of the activity.
    # @return [String, nil] Nil with no condition, thus the line does not start with a separator.
    def conditions(summary)
      condition = summary[:condition].presence
      return if condition.nil?

      spell = summary[:precipitation]
      spell ? "#{condition} with some #{spell[:condition]}" : condition
    end

    # "3–5 mph W wind with 8 mph gusts (55% headwind)".
    # @return [String]
    def wind(wind, headwind_percent, unit)
      speed = wind[:speed]
      text = [ "#{span(speed[:min], speed[:max])} #{unit}", wind[:direction], "wind" ].compact.join(" ")
      text += " with #{wind[:gust]} #{unit} gusts" if wind[:gust]
      text += " (#{headwind_percent}% headwind)" if headwind_percent
      text
    end

    # "64°F–71°F (feels like 62°F–72°F)", with the unit at each end.
    # @return [String, nil]
    def temperature(summary, unit)
      return if summary[:temperature].nil?

      text = temperature_range(summary[:temperature], unit)
      text += " (feels like #{temperature_range(summary[:feels_like], unit)})" if summary[:feels_like]
      text
    end

    # "70°F" for one value, "64°F–71°F" for two, and "−2°C to 2°C" when an end is negative: an en
    # dash beside a minus sign reads as a second minus sign.
    def temperature_range(range, unit)
      low = degrees(range[:min], unit)
      return low if range[:min] == range[:max]

      high = degrees(range[:max], unit)
      range[:min].negative? || range[:max].negative? ? "#{low} to #{high}" : "#{low}–#{high}"
    end

    def degrees(value, unit) = "#{value.negative? ? MINUS : ''}#{value.abs}#{unit}"

    # "3–5", or the top alone when the range starts at zero or has one value: "3", not "0–3".
    def span(min, max) = min.zero? || min == max ? max.to_s : "#{min}–#{max}"
  end
end
