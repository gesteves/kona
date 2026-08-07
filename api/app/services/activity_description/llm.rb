module ActivityDescription
  # The two Anthropic-backed lines of an activity description: the planned-workout summary
  # (🗓️) and the weather sentence. Both use structured outputs, so the response's first
  # text block is guaranteed to be valid JSON matching the schema. When ANTHROPIC_API_KEY
  # is unset both helpers return nil, and the description is composed without their lines.
  module Llm
    extend AnthropicStructuredOutput

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

    # @return [String] The env var that overrides the model for this caller.
    def anthropic_model_env = "ANTHROPIC_DESCRIPTION_MODEL"
  end
end
