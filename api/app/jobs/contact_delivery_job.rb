# Sends a complete contact-form email with Resend. This is the one part of the contact path that
# runs again after a failure: a failure of the delivery repeats the send only, and it never runs
# Akismet or the subject call again. Resend#send_email raises on a non-2xx, thus the retries from the
# parent class cover a temporary failure.
class ContactDeliveryJob < ApplicationJob
  # @param payload [Hash] The email that ContactMailJob makes: "to", "reply_to", "subject", "text",
  #   and "html".
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
