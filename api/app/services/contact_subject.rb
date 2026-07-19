# Generates a concise, descriptive email subject line for a contact-form submission, so the
# owner can triage the inbox at a glance instead of every message reading "New contact form
# message from …". Mirrors ActivityDescription::Llm: one structured-output Anthropic call with
# thinking disabled (a subject line doesn't benefit from reasoning, and adaptive thinking would
# eat into the tight token budget). Fails **soft** — returns nil when unconfigured, on a blank
# message, or on any error — and the caller (ContactMailJob) falls back to a static subject.
# A subject line is never worth failing or retrying the email over.
module ContactSubject
  SYSTEM_PROMPT = Rails.root.join("app/prompts/contact-subject.md").read.freeze

  DEFAULT_MODEL = "claude-sonnet-5".freeze
  MAX_TOKENS = 128
  TIMEOUT_SECONDS = 15

  module_function

  # @param name [String] The sender's name (context only — not required in the subject).
  # @param message [String] The message body to summarize.
  # @return [String, nil] A one-line subject, or nil when unconfigured / blank / on error.
  def generate(name:, message:)
    return if message.blank? || !configured?

    parsed = structured_call(
      user: "From: #{name}\n\nMessage:\n#{message}",
      schema: {
        type: "object",
        properties: { subject: { type: %w[string null] } },
        required: ["subject"],
        additionalProperties: false
      }
    )
    parsed[:subject].presence
  rescue StandardError => e
    ErrorReporter.report_upstream(e, service: "ContactSubject", context: "contact subject generation")
    nil
  end

  def configured?
    ENV["ANTHROPIC_API_KEY"].present?
  end

  def model
    ENV["ANTHROPIC_CONTACT_SUBJECT_MODEL"].presence || DEFAULT_MODEL
  end

  def client
    Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
  end

  # Makes a structured-output Anthropic call and parses the guaranteed-JSON text block.
  # @return [Hash] The parsed output with symbolized keys.
  def structured_call(user:, schema:)
    message = client.messages.create(
      model: model,
      max_tokens: MAX_TOKENS,
      thinking: { type: :disabled },
      system_: SYSTEM_PROMPT,
      messages: [{ role: "user", content: user }],
      output_config: { format: { type: :json_schema, schema: schema } },
      request_options: { timeout: TIMEOUT_SECONDS }
    )

    text = message.content.find { |block| block.type == :text }&.text
    JSON.parse(text.to_s, symbolize_names: true)
  end
end
