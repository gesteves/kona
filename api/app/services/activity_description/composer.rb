module ActivityDescription
  # Pure functions that build and assemble the description's blocks, plus the activity name
  # cleanup that rides along with them. Layout: an optional
  # user-written headline (preserved verbatim — never generated) sits above a stack of
  # emoji-prefixed stat lines, in order: planned summary (🗓️) · weather · water temp (💧) ·
  # power (⚡️) · heat (🌡️) · Whoop strain (🔥). No I/O — the generator gathers the data and
  # passes it in.
  module Composer
    # Codepoint ranges covering every emoji this module emits and every weather emoji the
    # LLM is likely to pick: Misc Symbols/Dingbats plus the main emoji blocks. Headline
    # content (user prose) starts with a letter, so this only ever strips stat-shaped lines.
    EMOJI_RANGES = [ 0x2600..0x27BF, 0x1F300..0x1F6FF, 0x1F900..0x1F9FF, 0x1FA00..0x1FAFF ].freeze

    # Rouvy names its uploads "ROUVY - <route> - <YYYY-MM-DD>".
    ROUVY_PREFIX = /\AROUVY\b/
    ROUVY_TRAILING_DATE = /\s*[-–—]\s*\d{4}-\d{2}-\d{2}\z/

    module_function

    # Assembles the final description: the preserved headline (blank-line separated) above
    # the emoji stat lines (joined by single newlines — a stacked stat block, not paragraphs).
    # @return [String] Empty when there's nothing to say.
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

    # Extracts the user-written headline from an existing description: every line that isn't
    # one of the emoji-prefixed stat lines, joined back together so multi-paragraph prose
    # round-trips (runs of blank lines collapse to one). Nil when nothing non-stat remains.
    # @return [String, nil]
    def headline(description)
      return if description.blank?

      kept = description.split("\n", -1).map(&:strip).filter_map do |line|
        next "" if line.empty? # preserve paragraph boundaries; trailing blanks fall to strip

        starts_with_emoji?(line) ? nil : line
      end

      kept.join("\n").gsub(/\n{3,}/, "\n\n").strip.presence
    end

    # Tidies a Rouvy-generated activity name: "ROUVY" becomes "Rouvy", and a trailing date drops
    # along with its hyphen when there is one. Any other name is returned unchanged.
    #
    # ⚠️ Gated on the uppercase prefix so a hand-written title that happens to end in a date is
    # never truncated.
    # @return [String, nil] nil when the name is blank.
    def clean_name(name)
      return if name.blank?
      return name unless name.match?(ROUVY_PREFIX)

      name.sub(ROUVY_PREFIX, "Rouvy").sub(ROUVY_TRAILING_DATE, "").strip
    end

    # The cycling power line, e.g. "⚡️ Avg 200 W · NP 210 W · IF 0.71 · TSS 98".
    # Partial data renders only the present fields; nil when the activity isn't cycling or
    # carries no power fields.
    # @param activity [Hash] Raw Intervals.icu activity (symbolized keys).
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

    # The CORE heat line, combining the per-activity HSI (requires both max and median) with
    # the daily heat-adaptation score (when positive). Suppressed for swims — the CORE
    # sensor is inaccurate in water. E.g. "🌡️ Max HSI 2.5 · Median HSI 1.7 · 72% heat adapted".
    # @return [String, nil]
    def heat_block(max_hsi:, median_hsi:, heat_adaptation_score:, swim:)
      return if swim

      has_hsi = max_hsi.present? && median_hsi.present?
      has_adaptation = heat_adaptation_score.is_a?(Numeric) && heat_adaptation_score.finite? && heat_adaptation_score.positive?
      return unless has_hsi || has_adaptation

      parts = []
      if has_hsi
        parts << "Max HSI #{format('%.1f', max_hsi)}"
        parts << "Median HSI #{format('%.1f', median_hsi)}"
      end
      parts << "#{heat_adaptation_score.round}% heat adapted" if has_adaptation

      "🌡️ #{parts.join(' · ')}"
    end

    # The Whoop strain line, e.g. "🔥 12.4 Whoop Strain". Suppressed for swims.
    # @return [String, nil]
    def whoop_block(strain, swim:)
      return if swim || strain.nil?

      "🔥 #{format('%.1f', strain)} Whoop Strain"
    end

    # The open-water swim water-temperature line, e.g. "💧 Water temperature 15.5 °C".
    # Whole degrees render without the trailing .0 ("59 °F", not "59.0 °F").
    # @param median_temp_celsius [Numeric, nil] Median of the activity's temp stream.
    # @param unit [Symbol] :celsius or :fahrenheit (the athlete's preference).
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

    # Whether a line leads with a pictographic emoji (one of our stat prefixes, the
    # LLM-picked weather emoji, or another tool's marker line).
    def starts_with_emoji?(line)
      codepoint = line.each_codepoint.first
      codepoint.present? && EMOJI_RANGES.any? { |range| range.cover?(codepoint) }
    end
  end
end
