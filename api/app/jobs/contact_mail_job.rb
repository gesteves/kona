require "erb"

# Delivers a contact-form submission to the owner, off the request path. Enqueued by
# Api::ContactController after it validates the input and drops honeypot hits. Runs the Akismet
# spam check here (not in the controller) so the request returns immediately; a spam verdict is
# logged and dropped. A clean message is emailed via Resend with Reply-To set to the sender, so
# a reply reaches the person who wrote in. Args are plain strings and delivery is effectively
# idempotent enough for the inherited retry: 5 (a rare duplicate email on retry is preferable to
# a lost message).
class ContactMailJob < ApplicationJob
  # @param name [String] The sender's name.
  # @param email [String] The sender's email (used as Reply-To).
  # @param message [String] The message body.
  # @param user_ip [String, nil] The real visitor IP, forwarded by the web proxy for Akismet.
  # @param user_agent [String, nil] The real visitor User-Agent, forwarded for Akismet.
  def perform(name, email, message, user_ip = nil, user_agent = nil)
    if Akismet.new.spam?(content: message, author: name, author_email: email, user_ip: user_ip, user_agent: user_agent)
      Rails.logger.info("Contact form: dropped a submission flagged as spam by Akismet")
      return
    end

    Resend.new.send_email(
      to: ENV["CONTACT_TO_ADDRESS"],
      reply_to: email,
      subject: "New contact form message from #{name}",
      text: text_body(name, email, message),
      html: html_body(name, email, message)
    )
    Rails.logger.info("Contact form: emailed a submission to the owner")
  end

  private

  # @return [String] The plain-text email body.
  def text_body(name, email, message)
    <<~BODY
      Name: #{name}
      Email: #{email}

      #{message}
    BODY
  end

  # @return [String] The HTML email body (all interpolated values are escaped).
  def html_body(name, email, message)
    h = ->(value) { ERB::Util.html_escape(value) }
    <<~HTML
      <p><strong>Name:</strong> #{h.call(name)}<br>
      <strong>Email:</strong> #{h.call(email)}</p>
      <p style="white-space: pre-wrap;">#{h.call(message)}</p>
    HTML
  end
end
