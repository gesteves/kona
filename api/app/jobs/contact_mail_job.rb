require "erb"
require "time"

# Delivers a contact-form submission to the owner, off the request path. Enqueued by
# Api::ContactController after it validates the input and drops honeypot hits. Runs the Akismet
# spam check here (not in the controller) so the request returns immediately; a spam verdict is
# logged and dropped. A clean message is emailed via Resend with Reply-To set to the sender, so
# a reply reaches the person who wrote in. Args are plain strings/hash and delivery is effectively
# idempotent enough for the inherited retry: 5 (a rare duplicate email on retry is preferable to
# a lost message).
class ContactMailJob < ApplicationJob
  # @param name [String] The sender's name.
  # @param email [String] The sender's email (used as Reply-To).
  # @param message [String] The message body.
  # @param context [Hash] String-keyed sender context forwarded by the web proxy: "ip",
  #   "user_agent", "city", "region", "country". Used for the Akismet check and the email's
  #   Sender details block. Any subset may be present.
  def perform(name, email, message, context = {})
    context ||= {}

    if Akismet.new.spam?(content: message, author: name, author_email: email,
      user_ip: context["ip"], user_agent: context["user_agent"])
      Rails.logger.info("Contact form: dropped a submission flagged as spam by Akismet")
      return
    end

    # A Claude-generated subject summarizing the message, for at-a-glance inbox triage; falls
    # back to a static subject when Anthropic is unconfigured or the call fails.
    subject = ContactSubject.generate(name: name, message: message).presence || "New contact form message from #{name}"

    Resend.new.send_email(
      to: ENV["CONTACT_TO_ADDRESS"],
      reply_to: email,
      subject: subject,
      text: text_body(name, email, message, context),
      html: html_body(name, email, message, context)
    )
    Rails.logger.info("Contact form: emailed a submission to the owner")
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
