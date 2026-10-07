module ActivityDescription
  # Functions that make the blocks of the description and put them together, and the code that
  # corrects the activity name. The layout: a headline that the user writes, which is optional and
  # which the code keeps with no change and never makes, goes above a group of stat lines. Each
  # stat line starts with an emoji, in this order: the map line of Zwift (🗺️), the planned summary
  # (🗓️), the weather, the water temperature (💧), the power (⚡️), the heat (🌡️), and the Whoop
  # strain (🔥). There is no I/O here: the generator collects the data and gives it to these
  # functions.
  module Composer
    # The emoji that start each stat line, with no U+FE0F. ⚠️ Only these mark a line that the code
    # wrote, thus a line that the owner starts with another emoji, for example "🏅 New PR", stays.
    # The set holds the emoji of each condition, the hot, cold, and moon-phase emoji of Weather, and
    # each weather emoji that the LLM selected in older descriptions.
    VARIATION_SELECTOR = "\uFE0F".freeze
    STAT_EMOJIS = (
      %w[🗓️ 💧 ⚡️ 🌡️ 🔥 ☀️ 🌤️ ⛅ 🌥️ ☁️ 🌦️ 🌧️ ⛈️ 🌩️ 🌨️ ❄️ 🌬️ 🌫️ 🌪️ 🌙] +
      CONDITIONS.values.flat_map { |condition| Array(condition[:emoji].is_a?(Hash) ? condition[:emoji].values : condition[:emoji]) } +
      Weather::MOON_EMOJI.values + [ Weather::HOT_EMOJI, Weather::COLD_EMOJI ]
    ).compact.map { |emoji| emoji.delete(VARIATION_SELECTOR) }.uniq.freeze

    # The emoji of the map line that Zwift writes in the description, for example
    # "🗺️ Waisted 8 in Watopia", with no U+FE0F. ⚠️ It is not a STAT_EMOJIS member: the code keeps
    # that line and moves it, and does not write it.
    MAP_EMOJI = "🗺".freeze

    # Rouvy gives each upload the name "ROUVY - <route> - <YYYY-MM-DD>".
    ROUVY_PREFIX = /\AROUVY\b/
    ROUVY_TRAILING_DATE = /\s*[-–—]\s*\d{4}-\d{2}-\d{2}\z/

    module_function

    # Makes the final description: the headline that the code keeps, with a blank line below it,
    # then the emoji stat lines with one newline between them. That gives a block of stat lines,
    # and not paragraphs.
    # @return [String] It is empty when there is no content.
    def compose(headline: nil, map: nil, planned: nil, weather: nil, water_temp: nil, power: nil, heat: nil, whoop: nil)
      blocks = []
      blocks << map if map.present?
      blocks << "🗓️ #{planned}" if planned.present?
      blocks << weather if weather.present?
      blocks << water_temp if water_temp.present?
      blocks << power if power.present?
      blocks << heat if heat.present?
      blocks << whoop if whoop.present?

      stat_section = blocks.join("\n")

      return "#{headline}\n\n#{stat_section}" if headline.present? && stat_section.present?
      return headline.to_s if headline.present?

      stat_section
    end

    # Gets the headline that the user wrote from a description: each line that is not one of the
    # stat lines with an emoji. It joins them again, thus text with more than one paragraph stays
    # the same, and a group of blank lines becomes one blank line. It gives nil when only the stat
    # lines stay.
    # @param map [Boolean] True to remove the map line of Zwift too. Refer to #map_line.
    # @return [String, nil]
    def headline(description, map: false)
      return if description.blank?

      kept = description.split("\n", -1).map(&:strip).filter_map do |line|
        next "" if line.empty? # preserve paragraph boundaries; trailing blanks fall to strip

        stat_line?(line) || (map && map_line?(line)) ? nil : line
      end

      kept.join("\n").gsub(/\n{3,}/, "\n\n").strip.presence
    end

    # Corrects an activity name that Rouvy makes: "ROUVY" becomes "Rouvy", and the code removes a
    # date at the end with its hyphen. Each other name stays the same.
    #
    # ⚠️ This runs only for the name with the uppercase text at the start. Thus the code never cuts
    # a title that a person writes and that ends with a date.
    # @return [String, nil] Nil when the name is blank.
    def clean_name(name)
      return if name.blank?
      return name unless name.match?(ROUVY_PREFIX)

      name.sub(ROUVY_PREFIX, "Rouvy").sub(ROUVY_TRAILING_DATE, "").strip
    end

    # The cycling power line, for example "⚡️ Avg 200 W · NP 210 W · IF 0.71 · TSS 98".
    # With some data absent, the line has only the fields that are available. It is nil when the
    # activity is not a bike ride, or when it has no power fields.
    # @param activity [Hash] The raw Intervals.icu activity, with symbol keys.
    # @return [String, nil]
    def power_block(activity)
      return unless ActivityMatcher.normalize_type(activity[:type]) == "Cycling"

      average = activity[:icu_average_watts] || activity[:average_watts]
      normalized = activity[:icu_weighted_avg_watts] || activity[:weighted_avg_watts]
      intensity = activity[:icu_intensity]
      tss = activity[:icu_training_load]

      parts = []
      parts << "Avg #{average.round} W" if average.present?
      parts << "NP #{normalized.round} W" if normalized.present?
      parts << "IF #{format('%.2f', intensity / 100.0)}" unless intensity.nil?
      parts << "TSS #{tss}" unless tss.nil?
      return if parts.empty?

      "⚡️ #{parts.join(' · ')}"
    end

    # The CORE heat line: the heat-adaptation score of the day, when it is more than zero. The
    # code omits it for a swim, because the CORE sensor is not accurate in water. For example,
    # "🌡️ 72% heat adapted".
    # @return [String, nil]
    def heat_block(heat_adaptation_score:)
      return unless heat_adaptation_score.is_a?(Numeric) && heat_adaptation_score.finite?
      return unless heat_adaptation_score.round.positive?

      "🌡️ #{heat_adaptation_score.round}% heat adapted"
    end

    # The Whoop strain line, for example "🔥 12.4 Whoop Strain". The code omits it for a swim.
    # @return [String, nil]
    def whoop_block(strain, swim:)
      return if swim || strain.nil?

      "🔥 #{format('%.1f', strain)} Whoop Strain"
    end

    # The water-temperature line for an open-water swim, for example
    # "💧 Water temperature 15.5°C". A value with no fraction has no ".0" at the end: "59°F", not
    # "59.0°F". There is no space before the unit, as in the weather line.
    # @param median_temp_celsius [Numeric, nil] The median of the temperature stream of the
    #   activity.
    # @param unit [Symbol] :celsius or :fahrenheit, which the athlete selects.
    # @return [String, nil]
    def water_temp_block(median_temp_celsius, unit:)
      return if median_temp_celsius.nil?

      formatted =
        if unit == :fahrenheit
          "#{format('%.1f', (median_temp_celsius * 9.0 / 5) + 32)}°F"
        else
          "#{format('%.1f', median_temp_celsius)}°C"
        end

      "💧 Water temperature #{formatted.sub(/\.0(?=°)/, '')}"
    end

    # @return [Boolean] True when a line starts with one of STAT_EMOJIS.
    # The map line that Zwift writes in the description of its activity. The composer puts it at the
    # top of the stat lines, with no blank line above them.
    # @return [String, nil] The first line that starts with MAP_EMOJI, or nil.
    def map_line(description)
      description.to_s.split("\n").map(&:strip).find { |line| map_line?(line) }
    end

    def map_line?(line) = line.delete(VARIATION_SELECTOR).start_with?(MAP_EMOJI)

    def stat_line?(line)
      plain = line.delete(VARIATION_SELECTOR)
      STAT_EMOJIS.any? { |emoji| plain.start_with?(emoji) }
    end
  end
end
