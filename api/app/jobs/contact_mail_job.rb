require "securerandom"

# The contact-form intake: the spam check, the abuse check, and the email, outside the request path.
# It gives the complete email to ContactDeliveryJob. That is a separate job, thus a Resend failure
# repeats only the send. The checks and the subject call each run one time, and not one time for
# each attempt to send.
class ContactMailJob < ContactJob
  # This goes at the start of each subject, thus the owner can make a filter for it. Do not change
  # it: a change breaks each filter that uses the old text.
  SUBJECT_PREFIX = "[Contact form]".freeze

  # @param name [String] The name of the sender.
  # @param email [String] The email address of the sender, which becomes the Reply-To.
  # @param message [String] The body of the message.
  # @param context [Hash] The sender data that the web proxy sends: some of "ip", "port",
  #   "user_agent", "city", "region", "country", and "network". Api::ContactController adds
  #   "received_at".
  # @param restored_from_spam [Boolean] True when the owner sends this message from the spam queue.
  #   The code then does no check, because the checks already ran and the owner decided against
  #   them. Admin::SpamController adds the Akismet ham report as a separate job.
  def perform(name, email, message, context = {}, restored_from_spam = false)
    context ||= {}

    # ⚠️ Each check must stay before its store, and no rescue goes around a check. Both checks fail
    # closed, thus a failure of the service raises and the job runs again. A store before a check,
    # or a rescue around it, would put correct mail that nothing checked in the quarantine or in the
    # inbox.
    unless restored_from_spam
      if Akismet.new.spam?(content: message, author: name, author_email: email,
        user_ip: context["ip"], user_agent: context["user_agent"])
        quarantine(name, email, message, context, SpamQuarantine::AKISMET)
        return
      end

      # This comes after Akismet, thus a spam message costs no Claude call.
      if ContactModeration.abusive?(name: name, message: message)
        quarantine(name, email, message, context, SpamQuarantine::ABUSIVE)
        return
      end
    end

    # This uses a fixed subject when there is no Anthropic configuration or when the call fails.
    generated = ContactSubject.generate(name: name, message: message).presence
    subject = "#{SUBJECT_PREFIX} #{generated || "New message from #{name}"}"

    # ⚠️ The key goes into the arguments, thus each attempt of the delivery job sends the same key.
    ContactDeliveryJob.perform_async(
      "to" => ENV["CONTACT_TO_ADDRESS"],
      "reply_to" => email,
      "subject" => subject,
      "text" => text_body(name, email, message, context),
      "idempotency_key" => SecureRandom.uuid
    )
  end

  private

  # Holds a marked message, thus the owner can read it and send it.
  # @param reason [String] The check that marked it: SpamQuarantine::AKISMET or ::ABUSIVE.
  # @return [void]
  def quarantine(name, email, message, context, reason)
    SpamQuarantine.new.store(name: name, email: email, message: message, context: context, reason: reason)
    Rails.logger.info("Contact form: quarantined a submission (#{reason})")
  end

  # @return [String] The plain-text body of the email.
  def text_body(name, email, message, context)
    <<~BODY
      Name: #{name}
      Email: #{email}

      #{message}

      —
      #{sender_details(context).join("\n")}
    BODY
  end

  # @return [Array<String>] The "Sender details" lines. It removes each blank line.
  def sender_details(context)
    location = [ context["city"], context["region"], context["country"] ].reject(&:blank?).join(", ")
    lines = []
    lines << "Location: #{location}" if location.present?
    lines << "IP: #{context["ip"]}" if context["ip"].present?
    lines << "Source port: #{context["port"]}" if context["port"].present?
    lines << "Network: #{context["network"]}" if context["network"].present?
    lines << "User agent: #{context["user_agent"]}" if context["user_agent"].present?
    lines << "Submitted: #{SubmissionTime.format(context["received_at"])}"
    lines
  end
end
