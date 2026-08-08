# Generates a descriptive email subject for a contact-form submission, so the inbox can be
# triaged at a glance. One structured-output Anthropic call with thinking disabled — a subject
# line doesn't benefit from reasoning, and it would eat the tight token budget.
#
# Fails soft: returns nil on any problem, and the caller falls back to a static subject. A
# subject line is never worth failing or retrying the email over.
module ContactSubject
  extend AnthropicStructuredOutput

  SYSTEM_PROMPT = Rails.root.join("app/prompts/contact-subject.md").read.freeze

  DEFAULT_MODEL = "claude-sonnet-5".freeze
  MAX_TOKENS = 128
  TIMEOUT_SECONDS = 15

  module_function

  # @return [String] The env var that overrides the model for this caller.
  def anthropic_model_env = "ANTHROPIC_CONTACT_SUBJECT_MODEL"

  # @param name [String] The sender's name, as context; it needn't appear in the subject.
  # @param message [String] The message to summarize.
  # @return [String, nil] A one-line subject, or nil when unconfigured, blank, or on error.
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
