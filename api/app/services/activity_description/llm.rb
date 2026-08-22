module ActivityDescription
  # The two lines of an activity description that Anthropic writes: the planned-workout summary
  # (🗓️) and the weather sentence. Both use a structured output, thus the first text block of the
  # response is always correct JSON that agrees with the schema. When ANTHROPIC_API_KEY has no
  # value, both methods return nil and the code makes the description without their lines.
  module Llm
    extend AnthropicStructuredOutput

    PLANNED_SUMMARY_PROMPT = Rails.root.join("app/prompts/planned-summary.md").read.freeze
    WEATHER_SENTENCE_PROMPT = Rails.root.join("app/prompts/weather-sentence.md").read.freeze

    DEFAULT_MODEL = "claude-sonnet-5".freeze
    MAX_TOKENS = 512
    # This is long for a one-sentence prompt. A longer time means that the call stopped. The app
    # already answered the webhook when these run, thus this limit only stops a large number of
    # jobs on the worker.
    TIMEOUT_SECONDS = 30

    module_function

    # Makes a one-sentence summary of a planned-workout description, with no period at the end. The
    # composer renders it as the 🗓️ line.
    # @return [String, nil] Nil when there is no configuration, when the input is blank, and when
    #   the model refuses because the description has too little content.
    # @raise [StandardError] On a transport failure. The generator catches the error for each call,
    #   thus only this line goes away.
    def planned_summary(planned_description)
      return if planned_description.blank? || !configured?

      parsed = structured_call(
        system: PLANNED_SUMMARY_PROMPT,
        user: "Planned workout description (summarize in one sentence):\n#{planned_description}",
        schema: {
          type: "object",
          properties: { planned_summary: { type: %w[string null] } },
          required: [ "planned_summary" ],
          additionalProperties: false
        }
      )
      parsed[:planned_summary].presence
    end

    # Changes a raw weather description into one sentence with an emoji at the start. The caller
    # does the indoor check: an indoor activity never gets a weather line.
    # @return [Hash, nil] { emoji:, sentence: }, or nil when there is no configuration, when the
    #   input is blank, and when the model refuses.
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

    # @return [String] The env var that replaces the model for this caller.
    def anthropic_model_env = "ANTHROPIC_DESCRIPTION_MODEL"
  end
end
