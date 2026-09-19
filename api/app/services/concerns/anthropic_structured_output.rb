require "anthropic"

# One Anthropic call with a structured output, or with a plain text answer. The services that make
# such a call share it: the lines of the activity description, the subject line of the contact
# form, and the alt text of a photo. They are different only in the env var that names their model
# and in their token and timeout limits, thus each other part is in the code one time.
#
# ⚠️ Use `extend` for this module, and not `include`. Both callers are `module_function` modules,
# thus their own methods are singleton methods, and they could not see the instance methods of a
# module that they include.
#
# The module that uses this supplies `DEFAULT_MODEL`, `MAX_TOKENS`, and `TIMEOUT_SECONDS`, and also
# `anthropic_model_env`, which names the env var that replaces the model.
module AnthropicStructuredOutput
  # @return [Boolean] True if an API key is available. Each caller gives nil without one.
  def configured?
    ENV["ANTHROPIC_API_KEY"].present?
  end

  # ⚠️ The code does not write the name of the env var here. Thus a `grep ENV\[` of the app does not
  # find ANTHROPIC_DESCRIPTION_MODEL and ANTHROPIC_CONTACT_SUBJECT_MODEL. They are in .env.example.
  # Look for `anthropic_model_env` when you compare the two.
  # @return [String] The model to call.
  def model
    ENV[anthropic_model_env].presence || self::DEFAULT_MODEL
  end

  # Makes an Anthropic call with a structured output. Such an output is always correct JSON that
  # agrees with the schema in its first text block. Thus a caller can parse it and does not need a
  # check for plain text.
  # @param system [String] The system prompt.
  # @param user [String] The user message.
  # @param schema [Hash] The JSON schema that the response must agree with.
  # @return [Hash] The parsed output, with symbol keys.
  def structured_call(system:, user:, schema:)
    message = create_message(system: system, content: user,
                             output_config: { format: { type: :json_schema, schema: schema } })
    JSON.parse(text_of(message).to_s, symbolize_names: true)
  end

  # Makes an Anthropic call whose answer is plain text.
  # @param system [String] The system prompt.
  # @param content [String, Array<Hash>] The user message: words, or an array of content blocks,
  #   for example an image and a text.
  # @return [String, nil] The first text block, stripped, or nil with none.
  def text_call(system:, content:)
    text_of(create_message(system: system, content: content))&.strip.presence
  end

  private

  # @param message [Anthropic::Models::Message]
  # @return [String, nil] The first text block of the answer.
  def text_of(message)
    message.content.find { |block| block.type == :text }&.text
  end

  # One `messages.create`, with the limits of the caller.
  # @param output_config [Hash, nil] The structured output, or nil for plain text.
  # @return [Anthropic::Models::Message]
  def create_message(system:, content:, output_config: nil)
    params = {
      model: model,
      max_tokens: self::MAX_TOKENS,
      # This is off. These short tasks do not need reasoning, and where adaptive thinking is on by
      # default it would use the small token budget and could cut the answer.
      thinking: { type: :disabled },
      system_: system,
      messages: [ { role: "user", content: content } ],
      request_options: { timeout: self::TIMEOUT_SECONDS }
    }
    params[:output_config] = output_config if output_config

    anthropic_client.messages.create(**params)
  end

  # The code keeps this value. Both callers made a new client for each call, and that read the key
  # again and made the connection configuration again for no purpose.
  def anthropic_client
    @anthropic_client ||= Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
  end
end
