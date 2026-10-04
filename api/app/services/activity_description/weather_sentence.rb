module ActivityDescription
  # Writes the weather line of an activity description from the summary of Weather, for example
  # "Overcast with 25 minutes of rain, SSE winds of 12–18 km/h and 24 km/h gusts (62% headwind),
  # and 11°C–13°C (feels like 8°C–10°C)". The emoji is not here: Weather#emoji gives it.
  #
  # ⚠️ This writes words and decides nothing. Weather already selected each part and rounded each
  # number, thus a change to what the line holds goes there. These are functions with no I/O.
  module WeatherSentence
    # A negative temperature takes a true minus sign, and not a hyphen.
    MINUS = "−".freeze

    module_function

    # The condition, then each part of the data joined with a serial comma. "with" joins the first
    # part to the condition when that part is the precipitation or the wind: "Clear with W winds of
    # 3 mph, 64°F–71°F, and AQI 39", but "Mostly clear, 52°F–54°F, and AQI 54".
    # @param summary [Hash] The summary of Weather.
    # @return [String] The sentence, with no emoji and no period at the end.
    def call(summary)
      units = summary[:units] || {}
      spell = summary[:precipitation]
      opening = [
        ("#{duration(spell[:minutes])} of #{spell[:condition]}" if spell),
        (wind(summary[:wind], summary[:headwind_percent], units[:wind]) if summary[:wind])
      ].compact
      rest = [
        temperature(summary, units[:temperature]),
        ("#{summary[:humidity_percent]}% humidity" if summary[:humidity_percent]),
        ("AQI #{summary[:aqi]}" if summary[:aqi])
      ].compact

      condition = summary[:condition].to_s
      parts = opening.any? ? [ "#{condition} with #{opening.first}", *opening.drop(1), *rest ] : [ condition, *rest ]
      parts.to_sentence(two_words_connector: ", ", last_word_connector: ", and ")
    end

    # "WNW winds of 3–5 mph and 9 mph gusts (62% headwind)".
    # @return [String]
    def wind(wind, headwind_percent, unit)
      speed = wind[:speed]
      text = [ wind[:direction], "winds of #{span(speed[:min], speed[:max])} #{unit}" ].compact.join(" ")
      text += " and #{wind[:gust]} #{unit} gusts" if wind[:gust]
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

    # "25 minutes", "1 hour", "1 hour 20 minutes", "2 hours".
    # @return [String]
    def duration(minutes)
      hours, rest = minutes.divmod(60)
      return "#{rest} #{'minute'.pluralize(rest)}" if hours.zero?

      text = "#{hours} #{'hour'.pluralize(hours)}"
      rest.zero? ? text : "#{text} #{rest} #{'minute'.pluralize(rest)}"
    end
  end
end
