require "anthropic"

# One structured-output Anthropic call, shared by the two services that make them: the activity
# description's generated lines and the contact form's subject line. They differed only in which
# env var names their model and in their token/timeout budgets, so everything else lived twice.
#
# ⚠️ `extend` this, don't `include` it. Both callers are `module_function` modules, so their own
# methods are singleton methods — an included module's instance methods would be invisible to them.
#
# The including module supplies `DEFAULT_MODEL`, `MAX_TOKENS` and `TIMEOUT_SECONDS`, plus
# `anthropic_model_env` naming the env var that overrides the model.
module AnthropicStructuredOutput
  # @return [Boolean] Whether an API key is configured. Every caller degrades to nil without one.
  def configured?
    ENV["ANTHROPIC_API_KEY"].present?
  end

  # ⚠️ The env var is named indirectly, so ANTHROPIC_DESCRIPTION_MODEL and
  # ANTHROPIC_CONTACT_SUBJECT_MODEL are invisible to a `grep ENV\[` audit of the app. They're in
  # .env.example; look for `anthropic_model_env` when reconciling the two.
  # @return [String] The model to call.
  def model
    ENV[anthropic_model_env].presence || self::DEFAULT_MODEL
  end

  # Makes a structured-output Anthropic call. Structured outputs guarantee the first text block is
  # valid JSON matching the schema, so callers can parse without defending against prose.
  # @param system [String] The system prompt.
  # @param user [String] The user message.
  # @param schema [Hash] The JSON schema the response must match.
  # @return [Hash] The parsed output, with symbolized keys.
  def structured_call(system:, user:, schema:)
    message = anthropic_client.messages.create(
      model: model,
      max_tokens: self::MAX_TOKENS,
      # Disabled: these one-sentence extractions don't benefit from reasoning, and where adaptive
      # thinking is on by default it would eat the tight token budget and risk truncating the JSON.
      thinking: { type: :disabled },
      system_: system,
      messages: [{ role: "user", content: user }],
      output_config: { format: { type: :json_schema, schema: schema } },
      request_options: { timeout: self::TIMEOUT_SECONDS }
    )

    text = message.content.find { |block| block.type == :text }&.text
    JSON.parse(text.to_s, symbolize_names: true)
  end

  private

  # Memoized: both callers built a fresh client per call, which re-reads the key and rebuilds the
  # connection config for nothing.
  def anthropic_client
    @anthropic_client ||= Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
  end
end
