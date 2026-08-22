# Makes a clear email subject for a contact-form submission, thus the owner can read the inbox
# quickly. It is one Anthropic call with a structured output and with the thinking off, because a
# subject line does not need reasoning and the thinking would use the small token budget.
#
# It fails soft: it returns nil for each problem, and the caller then uses a fixed subject. A
# subject line is never a reason to stop an email or to send it again.
module ContactSubject
  extend AnthropicStructuredOutput

  SYSTEM_PROMPT = Rails.root.join("app/prompts/contact-subject.md").read.freeze

  DEFAULT_MODEL = "claude-sonnet-5".freeze
  MAX_TOKENS = 128
  TIMEOUT_SECONDS = 15

  module_function

  # @return [String] The env var that replaces the model for this caller.
  def anthropic_model_env = "ANTHROPIC_CONTACT_SUBJECT_MODEL"

  # @param name [String] The name of the sender, as data for the model. It does not need to be in
  #   the subject.
  # @param message [String] The message to make a summary of.
  # @return [String, nil] A subject of one line, or nil when there is no configuration, when the
  #   message is blank, and on an error.
  def generate(name:, message:)
    return if message.blank? || !configured?

    parsed = structured_call(
      system: SYSTEM_PROMPT,
      user: "From: #{name}\n\nMessage:\n#{message}",
      schema: {
        type: "object",
        properties: { subject: { type: %w[string null] } },
        required: [ "subject" ],
        additionalProperties: false
      }
    )
    parsed[:subject].presence
  rescue StandardError => e
    ErrorReporter.report_upstream(e, service: "ContactSubject", context: "contact subject generation")
    nil
  end
end
