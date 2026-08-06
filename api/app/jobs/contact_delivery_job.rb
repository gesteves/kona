# Sends a fully-composed contact-form email via Resend. The single retryable unit of the contact
# pipeline: a delivery failure retries only the send, never re-running Akismet or the subject
# call. Resend#send_email raises on a non-2xx, so the inherited retries cover transient
# failures.
class ContactDeliveryJob < ApplicationJob
  # @param payload [Hash] The email, built by ContactMailJob: "to", "reply_to", "subject",
  #   "text", and "html".
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
