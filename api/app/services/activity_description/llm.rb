module ActivityDescription
  # The parts of an activity description that Anthropic writes: the planned-workout summary (🗓️),
  # and the words of a weather condition that changes. Both use a structured output, thus the
  # first text block of the response is always correct JSON that agrees with the schema. When
  # ANTHROPIC_API_KEY has no value, each method returns nil and the code writes the line without the
  # LLM.
  module Llm
    extend AnthropicStructuredOutput

    PLANNED_SUMMARY_PROMPT = Rails.root.join("app/prompts/planned-summary.md").read.freeze
    WEATHER_CONDITIONS_PROMPT = Rails.root.join("app/prompts/weather-conditions.md").read.freeze

    # The longest weather phrase that the code accepts. The prompt asks for 40 characters.
    MAX_WEATHER_CONDITIONS_LENGTH = 60
    # The time that Redis keeps the phrase of one list. The Strava run and the Whoop run of an
    # activity then write the same words, and the second run makes no new PUT.
    WEATHER_CONDITIONS_TTL = 30.days
    # ⚠️ `notes` comes before `phrase`, on purpose. The prompt makes the model count the
    # conditions, and without a field for that work the model writes it in the answer. The code
    # reads `phrase` only. ⚠️ Do not name the field `reasoning`: the API refuses that schema, with
    # `stop_reason: refusal` and no output.
    WEATHER_CONDITIONS_SCHEMA = {
      type: "object",
      properties: {
        notes: { type: "string" },
        phrase: { type: "string" }
      },
      required: %w[notes phrase],
      additionalProperties: false
    }.freeze

    DEFAULT_MODEL = "claude-sonnet-5-5".freeze
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

    # Summarizes the conditions of an activity whose condition changes in one phrase. Redis keeps
    # the phrase for each list, prompt, and model.
    # @param conditions [Array<String>] The `conditions` of the Weather summary, in time order.
    # @return [String, nil] The phrase, or nil when there is no configuration and when the phrase
    #   fails the checks of #valid_weather_conditions.
    # @raise [StandardError] On a transport failure. The generator catches it.
    def weather_conditions(conditions)
      return if conditions.blank? || !configured?

      list = conditions.join(", ")
      key = "activity:weather_conditions:#{Digest::SHA256.hexdigest([ WEATHER_CONDITIONS_PROMPT, model, list ].join("\x00"))[0, 16]}"
      cached = $redis.get(key)
      return cached if cached.present?

      parsed = structured_call(system: WEATHER_CONDITIONS_PROMPT, user: list, schema: WEATHER_CONDITIONS_SCHEMA)
      phrase = valid_weather_conditions(parsed[:phrase])
      $redis.setex(key, WEATHER_CONDITIONS_TTL.to_i, phrase) if phrase
      phrase
    end

    # ⚠️ Code writes each number of the line, thus a phrase with a digit goes away.
    # @return [String, nil] The phrase, or nil when it is blank, too long, on more than one line, or
    #   holds a digit or the separator of the line.
    def valid_weather_conditions(text)
      text = text.to_s.strip.delete_prefix('"').delete_suffix('"').delete_suffix(".")
      return if text.empty? || text.length > MAX_WEATHER_CONDITIONS_LENGTH
      return if text.match?(/[\d\n·]/)

      text
    end

    # @return [String] The env var that replaces the model for this caller.
    def anthropic_model_env = "ANTHROPIC_DESCRIPTION_MODEL"
  end
end
