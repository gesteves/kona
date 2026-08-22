require "erb"
require "time"

# The contact-form intake: the spam check and the email, outside the request path. It gives the
# complete email to ContactDeliveryJob. That is a separate job, thus a Resend failure repeats only
# the send. Akismet and the subject call each run one time, and not one time for each attempt to
# send.
class ContactMailJob < ApplicationJob
  # This goes at the start of each subject, thus the owner can make a filter for it. Do not change
  # it: a change breaks each filter that uses the old text.
  SUBJECT_PREFIX = "[Contact form]".freeze

  # @param name [String] The name of the sender.
  # @param email [String] The email address of the sender, which becomes the Reply-To.
  # @param message [String] The body of the message.
  # @param context [Hash] The sender data that the web proxy sends: some of "ip", "user_agent",
  #   "city", "region", and "country". The spam quarantine adds "received_at".
  # @param restored_from_spam [Boolean] True when the owner sends this message from the spam queue.
  #   The code then does not do the Akismet check, because that check already ran and the owner
  #   decided against it. It also tells Akismet that the mark was incorrect, thus Akismet stops the
  #   mark on the same sender. The name says the condition, and not one of the two actions, because
  #   it controls both and they always occur together.
  def perform(name, email, message, context = {}, restored_from_spam = false)
    context ||= {}

    if restored_from_spam
      report_false_positive(name, email, message, context)
    elsif Akismet.new.spam?(content: message, author: name, author_email: email,
      user_ip: context["ip"], user_agent: context["user_agent"])
      # ⚠️ The Akismet call must stay before this code. It fails closed, thus a failure of the
      # service raises and the job runs again. A store before it, or a rescue around it, would fill
      # the quarantine with correct mail that nothing checked, during an Akismet failure.
      SpamQuarantine.new.store(name: name, email: email, message: message, context: context)
      Rails.logger.info("Contact form: quarantined a submission flagged as spam by Akismet")
      return
    end

    # This uses a fixed subject when there is no Anthropic configuration or when the call fails.
    generated = ContactSubject.generate(name: name, message: message).presence
    subject = "#{SUBJECT_PREFIX} #{generated || "New message from #{name}"}"

    ContactDeliveryJob.perform_async(
      "to" => ENV["CONTACT_TO_ADDRESS"],
      "reply_to" => email,
      "subject" => subject,
      "text" => text_body(name, email, message, context),
      "html" => html_body(name, email, message, context)
    )
  end

  private

  # Tells Akismet that its mark on a message was incorrect, after the owner sends that message. It
  # never raises: this is training, and the app sends the message in both conditions.
  # @return [void]
  def report_false_positive(name, email, message, context)
    Akismet.new.submit_ham(content: message, author: name, author_email: email,
      user_ip: context["ip"], user_agent: context["user_agent"])
    Rails.logger.info("Contact form: reported a false positive to Akismet")
  rescue StandardError => e
    Rails.logger.warn("Contact form: could not report a false positive to Akismet (#{e.class}: #{e.message})")
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

  # @return [String] The HTML body of the email. The code escapes each value that it adds.
  def html_body(name, email, message, context)
    h = ->(value) { ERB::Util.html_escape(value) }
    details = sender_details(context).map { |line| h.call(line) }.join("<br>")
    <<~HTML
      <p><strong>Name:</strong> #{h.call(name)}<br>
      <strong>Email:</strong> #{h.call(email)}</p>
      <p style="white-space: pre-wrap;">#{h.call(message)}</p>
      <hr>
      <p style="color: #888; font-size: 0.85em;">#{details}</p>
    HTML
  end

  # @return [Array<String>] The "Sender details" lines. It removes each blank line.
  def sender_details(context)
    location = [ context["city"], context["region"], context["country"] ].reject(&:blank?).join(", ")
    lines = []
    lines << "Location: #{location}" if location.present?
    lines << "IP: #{context["ip"]}" if context["ip"].present?
    lines << "User agent: #{context["user_agent"]}" if context["user_agent"].present?
    # A message from the quarantine has the time of its submission. The code makes a new message
    # some seconds after it arrives, thus "now" is sufficiently accurate.
    lines << "Submitted: #{context["received_at"].presence || Time.now.utc.iso8601}"
    lines
  end
end
