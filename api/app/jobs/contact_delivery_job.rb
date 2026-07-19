# Sends a fully-composed contact-form email via Resend. Enqueued by ContactMailJob after the
# spam check + composition, so this is the single retryable unit of the contact pipeline: a
# Resend failure retries only the send and never re-runs Akismet or the Claude subject call.
# Resend#send_email raises on a non-2xx, so the inherited retry: 5 covers transient delivery
# failures; exhausted retries land in the Dead set.
class ContactDeliveryJob < ApplicationJob
  # @param payload [Hash] String-keyed, built by ContactMailJob: "to", "reply_to", "subject",
  #   "text", "html".
  def perform(payload)
    Resend.new.send_email(
      to: payload["to"],
      reply_to: payload["reply_to"],
      subject: payload["subject"],
      text: payload["text"],
      html: payload["html"]
    )
    Rails.logger.info("Contact form: emailed a submission to the owner")
  end
end
