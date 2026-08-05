require "erb"
require "time"

# Contact-form intake: the spam gate + email composition, off the request path. Enqueued by
# Api::ContactController. Runs the Akismet check (fail-open) and, for a clean submission,
# generates the subject and composes the email, then hands the finished email to
# ContactDeliveryJob to send. Delivery is a separate job so a Resend failure retries *only the
# send* — Akismet and the Claude subject call each run exactly once, not once per delivery retry.
# In practice this job never retries: Akismet fails open and ContactSubject fails soft (neither
# raises), so nothing here fails except a Redis hiccup on the enqueue.
class ContactMailJob < ApplicationJob
  # Prefixed onto every subject — generated or fallback — so the owner can filter on it in their
  # mail client. Keep it stable: changing it breaks any filter keyed on the old string.
  SUBJECT_PREFIX = "[Contact form]".freeze

  # @param name [String] The sender's name.
  # @param email [String] The sender's email (used as Reply-To).
  # @param message [String] The message body.
  # @param context [Hash] String-keyed sender context forwarded by the web proxy: "ip",
  #   "user_agent", "city", "region", "country". Any subset may be present.
  def perform(name, email, message, context = {})
    context ||= {}

    if Akismet.new.spam?(content: message, author: name, author_email: email,
      user_ip: context["ip"], user_agent: context["user_agent"])
      Rails.logger.info("Contact form: dropped a submission flagged as spam by Akismet")
      return
    end

    # A Claude-generated subject summarizing the message, for at-a-glance inbox triage; falls
    # back to a static subject when Anthropic is unconfigured or the call fails. Either way it
    # carries SUBJECT_PREFIX, so a mail filter can match every contact-form message.
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

  # @return [String] The plain-text email body.
  def text_body(name, email, message, context)
    <<~BODY
      Name: #{name}
      Email: #{email}

      #{message}

      —
      #{sender_details(context).join("\n")}
    BODY
  end

  # @return [String] The HTML email body (all interpolated values are escaped).
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

  # Human-readable "Sender details" lines from the proxy-forwarded context, blanks omitted.
  # @return [Array<String>]
  def sender_details(context)
    location = [context["city"], context["region"], context["country"]].reject(&:blank?).join(", ")
    lines = []
    lines << "Location: #{location}" if location.present?
    lines << "IP: #{context["ip"]}" if context["ip"].present?
    lines << "User agent: #{context["user_agent"]}" if context["user_agent"].present?
    lines << "Submitted: #{Time.now.utc.iso8601}"
    lines
  end
end
