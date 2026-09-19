require "base64"

# Writes the alt text of a photo on the Social media page, with Claude. It is one Anthropic call
# with the picture in the user message and a plain text answer, with the thinking off.
#
# It fails soft: it returns nil for each problem, and the page then says so in a toast and keeps
# the field as it was. A description is never a reason to lose a draft.
module AltText
  extend AnthropicStructuredOutput

  SYSTEM_PROMPT = Rails.root.join("app/prompts/alt-text.md").read.freeze

  DEFAULT_MODEL = "claude-sonnet-5".freeze
  MAX_TOKENS = 512
  # ⚠️ This call runs in a REQUEST, inside the 20-second rack-timeout, and not in a job. A longer
  # timeout would give a 500 in place of a toast.
  TIMEOUT_SECONDS = 15

  # The one instruction of the user message. The system prompt says what to write.
  USER_TEXT = "Write the alt text for this image.".freeze

  module_function

  # @return [String] The env var that replaces the model for this caller.
  def anthropic_model_env = "ANTHROPIC_ALT_TEXT_MODEL"

  # @param image [String] The bytes of the picture.
  # @param media_type [String] Its content type. The photos of a draft are always JPEG.
  # @return [String, nil] The alt text, at most `Bluesky::MAX_ALT_GRAPHEMES` long, or nil when
  #   there is no configuration, when the picture is blank, and on an error.
  def generate(image:, media_type: "image/jpeg")
    return if image.blank? || !configured?

    text = text_call(
      system: SYSTEM_PROMPT,
      content: [
        { type: :image,
          source: { type: :base64, media_type: media_type.to_sym, data: Base64.strict_encode64(image) } },
        { type: :text, text: USER_TEXT }
      ]
    )
    truncate(text)
  rescue StandardError => e
    ErrorReporter.report_upstream(e, service: "AltText", context: "alt text generation")
    nil
  end

  # ⚠️ The prompt asks for less than 1,000 characters, and the field takes 2000 graphemes. This is
  # the guard for an answer that ignores the prompt: the action would otherwise refuse the draft.
  # @param text [String, nil]
  # @return [String, nil]
  def truncate(text)
    return if text.blank?

    text.scan(/\X/).first(Bluesky::MAX_ALT_GRAPHEMES).join
  end
end
