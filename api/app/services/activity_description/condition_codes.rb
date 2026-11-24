module ActivityDescription
  # What config/conditions.yml says about a WeatherKit condition code, for the weather line of an
  # activity: its words, its emoji, and its kind.
  module ConditionCodes
    # The cloud cover, in percent, below which each condition applies, for a sky with no sky code:
    # the Intervals.icu fallback, and a track where each hour is, for example, Windy. Above the last
    # step, it is Cloudy.
    CLOUD_CONDITIONS = [ [ 13, "Clear" ], [ 38, "MostlyClear" ], [ 63, "PartlyCloudy" ], [ 88, "MostlyCloudy" ] ].freeze
    SKY_CODES = [ *CLOUD_CONDITIONS.map(&:last), "Cloudy" ].freeze

    module_function

    # @return [Boolean] True for a code that config/conditions.yml has.
    def known?(code) = CONDITIONS.key?(code.to_sym)

    # @return [String] The words of a code, from its `simplified` phrase.
    def phrase(code)
      CONDITIONS.dig(code.to_sym, :phrases, :simplified) || code.underscore.humanize
    end

    # The phrase of a code for a fact: "mixed rain and snow", and not "Mixed rain & snow".
    def fact_phrase(code) = phrase(code).downcase.gsub("&", "and")

    # ⚠️ The type comes from `precipitation`, and not from `adverse_weather`, which also marks wind,
    # haze, smoke, fog, and cold.
    # @return [String, nil] The type of precipitation of a code, or nil for a dry code.
    def precipitation_type(code) = CONDITIONS.dig(code.to_sym, :precipitation)

    # @param code [String, nil]
    # @return [Boolean] True for a code that config/conditions.yml marks as adverse weather.
    def adverse?(code) = code.present? && CONDITIONS.dig(code.to_sym, :adverse_weather) == true

    # @param daylight [Boolean] True for the day emoji of a code that has two.
    # @return [String, nil] The emoji of a code, or nil for a code with none.
    def emoji(code, daylight:)
      emoji = CONDITIONS.dig(code.to_sym, :emoji)
      emoji.is_a?(Hash) ? emoji[daylight ? :day : :night] : emoji
    end

    # @return [String] The code of SKY_CODES for a cloud cover in percent.
    def for_cloud_cover(percent) = CLOUD_CONDITIONS.find { |limit, _code| percent < limit }&.last || "Cloudy"
  end
end
