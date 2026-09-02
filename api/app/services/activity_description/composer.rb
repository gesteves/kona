module ActivityDescription
  # Functions that make the blocks of the description and put them together, and the code that
  # corrects the activity name. The layout: a headline that the user writes, which is optional and
  # which the code keeps with no change and never makes, goes above a group of stat lines. Each
  # stat line starts with an emoji, in this order: the planned summary (🗓️), the weather, the water
  # temperature (💧), the power (⚡️), the heat (🌡️), and the Whoop strain (🔥). There is no I/O
  # here: the generator collects the data and gives it to these functions.
  module Composer
    # The code point ranges for each emoji that this module writes and for each weather emoji that
    # the LLM can select: Miscellaneous Symbols, Dingbats, and the main emoji blocks. The text of a
    # headline, which the user writes, starts with a letter. Thus this only removes a line with the
    # shape of a stat line.
    EMOJI_RANGES = [ 0x2600..0x27BF, 0x1F300..0x1F6FF, 0x1F900..0x1F9FF, 0x1FA00..0x1FAFF ].freeze

    # Rouvy gives each upload the name "ROUVY - <route> - <YYYY-MM-DD>".
    ROUVY_PREFIX = /\AROUVY\b/
    ROUVY_TRAILING_DATE = /\s*[-–—]\s*\d{4}-\d{2}-\d{2}\z/

    module_function

    # Makes the final description: the headline that the code keeps, with a blank line below it,
    # then the emoji stat lines with one newline between them. That gives a block of stat lines,
    # and not paragraphs.
    # @return [String] It is empty when there is no content.
    def compose(headline: nil, planned: nil, weather: nil, water_temp: nil, power: nil, heat: nil, whoop: nil)
      blocks = []
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
    # @return [String, nil]
    def headline(description)
      return if description.blank?

      kept = description.split("\n", -1).map(&:strip).filter_map do |line|
        next "" if line.empty? # preserve paragraph boundaries; trailing blanks fall to strip

        starts_with_emoji?(line) ? nil : line
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
    # "💧 Water temperature 15.5 °C". A value with no fraction has no ".0" at the end: "59 °F", not
    # "59.0 °F".
    # @param median_temp_celsius [Numeric, nil] The median of the temperature stream of the
    #   activity.
    # @param unit [Symbol] :celsius or :fahrenheit, which the athlete selects.
    # @return [String, nil]
    def water_temp_block(median_temp_celsius, unit:)
      return if median_temp_celsius.nil?

      formatted =
        if unit == :fahrenheit
          "#{format('%.1f', (median_temp_celsius * 9.0 / 5) + 32)} °F"
        else
          "#{format('%.1f', median_temp_celsius)} °C"
        end

      "💧 Water temperature #{formatted.sub(/\.0(?=\s|\z)/, '')}"
    end

    # Tells if a line starts with an emoji: one of the stat emoji of this app, the weather emoji
    # that the LLM selects, or the marker line of another tool.
    def starts_with_emoji?(line)
      codepoint = line.each_codepoint.first
      codepoint.present? && EMOJI_RANGES.any? { |range| range.cover?(codepoint) }
    end
  end
end
