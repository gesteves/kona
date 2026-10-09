require 'anthropic'
require_relative 'format'

module RaceWeather
  # Writes the Weather cell of one day. Claude writes it from the conditions of each hour. Without
  # a key, or on a failure, the cell is the most common condition of the day.
  module Summary
    extend self

    DEFAULT_MODEL = 'claude-sonnet-5-5'.freeze
    PROMPT = File.read(File.expand_path('../../prompts/weather-summary.md', __dir__)).freeze
    MAX_LENGTH = 60
    MAX_TOKENS = 100
    TIMEOUT_SECONDS = 30

    # @return [Boolean] True when the Anthropic key has a value.
    def configured?
      !ENV['ANTHROPIC_API_KEY'].to_s.empty?
    end

    # @param hours [Array<Hash>] The WeatherKit hours, with `localHour`.
    # @return [Array(String, Symbol)] The phrase, and :claude or :fallback.
    def phrase(hours)
      if configured?
        text = valid(claude(hours))
        return [text, :claude] if text

        warn '  Claude gave no valid phrase, the Weather cell uses the fallback'
      end
      [fallback(hours), :fallback]
    rescue Anthropic::Errors::Error => e
      warn "  Claude failed (#{e.class.name.split('::').last}), the Weather cell uses the fallback"
      [fallback(hours), :fallback]
    end

    # @return [String, nil] The most common condition of the day, as words.
    def fallback(hours)
      code = hours.filter_map { |hour| hour['conditionCode'] }.tally.max_by { |_, count| count }&.first
      code && Format.condition_words(code)
    end

    # @return [String] One line for each hour, for example "3 PM: Mostly cloudy, rain 0.04 mm".
    def hour_lines(hours)
      hours.map do |hour|
        line = "#{Format.clock(hour['localHour'])}: #{Format.condition_words(hour['conditionCode'])}"
        amount = hour['precipitationAmount'].to_f
        line += ", #{hour['precipitationType'] || 'precipitation'} #{amount.round(2)} mm" if amount.positive?
        line
      end.join("\n")
    end

    private

    def claude(hours)
      message = client.messages.create(
        model: model,
        max_tokens: MAX_TOKENS,
        thinking: { type: thinking_off_type },
        system_: PROMPT,
        messages: [{ role: 'user', content: hour_lines(hours) }],
        request_options: { timeout: TIMEOUT_SECONDS }
      )
      message.content.find { |block| block.type == :text }&.text
    end

    # @return [String, nil] The phrase, or nil when it is empty, too long, or more than one line.
    def valid(text)
      text = text.to_s.strip.delete_prefix('"').delete_suffix('"').strip.chomp('.')
      text if !text.empty? && text.length <= MAX_LENGTH && !text.include?("\n")
    end

    def model
      ENV['ANTHROPIC_MODEL'].to_s.empty? ? DEFAULT_MODEL : ENV['ANTHROPIC_MODEL']
    end

    # ⚠️ Claude Sonnet 5.5 gives a 400 for `disabled`, and each other model gives a 400 for
    # `between_tools`. The api has the same rule.
    def thinking_off_type
      model == 'claude-sonnet-5-5' ? :between_tools : :disabled
    end

    def client
      @client ||= Anthropic::Client.new(api_key: ENV.fetch('ANTHROPIC_API_KEY'))
    end
  end
end
