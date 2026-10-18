# Sends a complete contact-form email with Resend. This is a separate job, thus a failure of the
# delivery repeats the send only, and it never runs Akismet, the abuse check, or the subject call
# again. Resend#send_email raises on a non-2xx, thus the retries from the parent class cover a
# temporary failure.
#
# ⚠️ Resend keeps an idempotency key for 24 hours only, and the retries go on for much longer. Thus
# a send that succeeds and loses its response after that window can give a second email at the next
# attempt. A copy of an email costs less than a lost message.
class ContactDeliveryJob < ContactJob
  # @param payload [Hash] The email that ContactMailJob makes: "to", "reply_to", "subject",
  #   "text", and "idempotency_key".
  def perform(payload)
    Resend.new.send_email(
      to: payload["to"],
      reply_to: payload["reply_to"],
      subject: payload["subject"],
      text: payload["text"],
      idempotency_key: payload["idempotency_key"]
    )
    Rails.logger.info("Contact form: emailed a submission to the owner")
  end
end
