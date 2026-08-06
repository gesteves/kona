module ActivityDescription
  # The two Anthropic-backed lines of an activity description: the planned-workout summary
  # (🗓️) and the weather sentence. Both use structured outputs, so the response's first
  # text block is guaranteed to be valid JSON matching the schema. When ANTHROPIC_API_KEY
  # is unset both helpers return nil, and the description is composed without their lines.
  module Llm
    PLANNED_SUMMARY_PROMPT = Rails.root.join("app/prompts/planned-summary.md").read.freeze
    WEATHER_SENTENCE_PROMPT = Rails.root.join("app/prompts/weather-sentence.md").read.freeze

    DEFAULT_MODEL = "claude-sonnet-5".freeze
    MAX_TOKENS = 512
    # Generous for these one-sentence prompts; anything longer is a degenerate stall. The
    # webhook is already acked by the time these run, so this just bounds worker pile-up.
    TIMEOUT_SECONDS = 30

    module_function

    # Summarizes a planned-workout description into a one-sentence phrase, with no trailing
    # period — the composer renders it as the 🗓️ line.
    # @return [String, nil] Nil when unconfigured, blank, or declined for a sparse description.
    # @raise [StandardError] on transport failure; the generator rescues per-call, so only this
    #   line is lost.
    def planned_summary(planned_description)
      return if planned_description.blank? || !configured?

      parsed = structured_call(
        system: PLANNED_SUMMARY_PROMPT,
        user: "Planned workout description (summarize in one sentence):\n#{planned_description}",
        schema: {
          type: "object",
          properties: { planned_summary: { type: %w[string null] } },
          required: ["planned_summary"],
          additionalProperties: false
        }
      )
      parsed[:planned_summary].presence
    end

    # Rewrites a raw weather description as one sentence plus a leading emoji. The caller owns
    # the indoor check — indoor activities never get a weather line.
    # @return [Hash, nil] { emoji:, sentence: }, or nil when unconfigured, blank, or declined.
    def weather_sentence(weather_description)
      return if weather_description.blank? || !configured?

      parsed = structured_call(
        system: WEATHER_SENTENCE_PROMPT,
        user: "Weather data: #{weather_description}",
        schema: {
          type: "object",
          properties: {
            weather_emoji: { type: %w[string null] },
            weather_sentence: { type: %w[string null] }
          },
          required: %w[weather_emoji weather_sentence],
          additionalProperties: false
        }
      )
      return if parsed[:weather_emoji].blank? || parsed[:weather_sentence].blank?

      { emoji: parsed[:weather_emoji], sentence: parsed[:weather_sentence] }
    end

    def configured?
      ENV["ANTHROPIC_API_KEY"].present?
    end

    def model
      ENV["ANTHROPIC_DESCRIPTION_MODEL"].presence || DEFAULT_MODEL
    end

    def client
      Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
    end

    # Makes a structured-output Anthropic call.
    # @return [Hash] The parsed output, with symbolized keys.
    def structured_call(system:, user:, schema:)
      message = client.messages.create(
        model: model,
        max_tokens: MAX_TOKENS,
        # Disabled: these one-sentence extractions don't benefit from reasoning, and where
        # adaptive thinking is on by default it would eat the tight MAX_TOKENS budget and
        # risk truncating the JSON.
        thinking: { type: :disabled },
        system_: system,
        messages: [{ role: "user", content: user }],
        output_config: { format: { type: :json_schema, schema: schema } },
        request_options: { timeout: TIMEOUT_SECONDS }
      )

      text = message.content.find { |block| block.type == :text }&.text
      JSON.parse(text.to_s, symbolize_names: true)
    end
  end
end
