# Finds a contact-form submission that is abusive: an insult, a threat, harassment, or hate. Such a
# message is not spam, thus Akismet does not stop it. It is one Anthropic call with a structured
# output and with the thinking off.
#
# ⚠️ It fails **closed** when it has a configuration, as Akismet does: each error except a refusal
# raises, thus the intake job runs again and no message reaches the inbox with no check. Do not
# put a rescue around it. With no ANTHROPIC_API_KEY the check is off.
module ContactModeration
  extend AnthropicStructuredOutput

  SYSTEM_PROMPT = Rails.root.join("app/prompts/contact-moderation.md").read.freeze

  DEFAULT_MODEL = "claude-sonnet-5-5".freeze
  MAX_TOKENS = 64
  TIMEOUT_SECONDS = 15

  SCHEMA = {
    type: "object",
    properties: { abusive: { type: "boolean" } },
    required: [ "abusive" ],
    additionalProperties: false
  }.freeze

  module_function

  # @return [String] The env var that replaces the model for this caller.
  def anthropic_model_env = "ANTHROPIC_CONTACT_MODERATION_MODEL"

  # @param name [String] The name of the sender, which can also hold an insult.
  # @param message [String] The message to check.
  # @return [Boolean] True if the message is abusive, or if the model refuses it. False when there
  #   is no configuration and when the message is blank.
  # @raise [StandardError] On each other failure.
  def abusive?(name:, message:)
    return false if message.blank? || !configured?

    parsed = structured_call(system: SYSTEM_PROMPT, user: "From: #{name}\n\nMessage:\n#{message}", schema: SCHEMA)
    parsed[:abusive] == true
  rescue AnthropicStructuredOutput::Refusal
    # A message that starts a safety classifier must not go to the inbox with no check.
    true
  end
end
