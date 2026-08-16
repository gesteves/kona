require "erb"
require "time"

# Contact-form intake: the spam check and email composition, off the request path. Hands the
# finished email to ContactDeliveryJob, which is a separate job so a Resend failure retries only
# the send — Akismet and the subject call each run exactly once, not once per delivery retry.
class ContactMailJob < ApplicationJob
  # Prefixed onto every subject, so the owner can filter on it. Keep it stable — changing it
  # breaks any filter keyed on the old string.
  SUBJECT_PREFIX = "[Contact form]".freeze

  # @param name [String] The sender's name.
  # @param email [String] The sender's email, used as Reply-To.
  # @param message [String] The message body.
  # @param context [Hash] Sender context forwarded by the web proxy: any subset of "ip",
  #   "user_agent", "city", "region", and "country". The spam quarantine adds "received_at".
  # @param restored_from_spam [Boolean] True when the owner released this from the spam queue.
  #   Skips the Akismet check — it already ran and was overruled — and reports the false positive
  #   back so the same sender stops being flagged. Named for the situation rather than either
  #   behavior, because it drives both and they only ever coincide.
  def perform(name, email, message, context = {}, restored_from_spam = false)
    context ||= {}

    if restored_from_spam
      report_false_positive(name, email, message, context)
    elsif Akismet.new.spam?(content: message, author: name, author_email: email,
      user_ip: context["ip"], user_agent: context["user_agent"])
      # ⚠️ The Akismet call stays ahead of this. It fails closed, so an outage raises and the job
      # retries; storing first, or rescuing around it, would fill the quarantine with unchecked
      # legitimate mail during an Akismet outage.
      SpamQuarantine.new.store(name: name, email: email, message: message, context: context)
      Rails.logger.info("Contact form: quarantined a submission flagged as spam by Akismet")
      return
    end

    # Falls back to a static subject when Anthropic is unconfigured or the call fails.
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

  # Tells Akismet it was wrong about a message the owner released. Never raises: this is training,
  # and the message is being delivered either way.
  # @return [void]
  def report_false_positive(name, email, message, context)
    Akismet.new.submit_ham(content: message, author: name, author_email: email,
      user_ip: context["ip"], user_agent: context["user_agent"])
    Rails.logger.info("Contact form: reported a false positive to Akismet")
  rescue StandardError => e
    Rails.logger.warn("Contact form: could not report a false positive to Akismet (#{e.class}: #{e.message})")
  end

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

  # @return [String] The HTML email body, with every interpolated value escaped.
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

  # @return [Array<String>] The "Sender details" lines, with blanks omitted.
  def sender_details(context)
    location = [ context["city"], context["region"], context["country"] ].reject(&:blank?).join(", ")
    lines = []
    lines << "Location: #{location}" if location.present?
    lines << "IP: #{context["ip"]}" if context["ip"].present?
    lines << "User agent: #{context["user_agent"]}" if context["user_agent"].present?
    # A released message carries the time it was actually submitted; a fresh one is composed
    # within seconds of arriving, so "now" is close enough.
    lines << "Submitted: #{context["received_at"].presence || Time.now.utc.iso8601}"
    lines
  end
end
