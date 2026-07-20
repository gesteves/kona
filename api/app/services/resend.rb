require "httparty"

# Sends transactional email through the Resend HTTP API. Used by ContactMailJob to deliver
# contact-form messages to the owner. It's an HTTPS call (port 443), so it works from fly —
# which blocks outbound SMTP — and it needs only SPF/DKIM DNS records, so it coexists with a
# Google Workspace mailbox on the same domain (it never touches the root MX).
#
# @see https://resend.com/docs/api-reference/emails/send-email
class Resend < ApplicationService
  RESEND_API_URL = "https://api.resend.com/emails"

  # @param api_key [String] The Resend API key.
  # @param from [String] The verified sender address (on a domain verified in Resend).
  def initialize(api_key: ENV["RESEND_API_KEY"], from: ENV["CONTACT_FROM_ADDRESS"])
    @api_key = api_key
    @from = from
  end

  # @return [Boolean] Whether the key + sender needed to send are present.
  def configured?
    @api_key.present? && @from.present?
  end

  # Sends an email. Raises on failure so the caller's Sidekiq retry can pick it up.
  # @param to [String] Recipient address.
  # @param subject [String] Subject line.
  # @param text [String] Plain-text body (always sent, for deliverability).
  # @param html [String, nil] Optional HTML body.
  # @param reply_to [String, nil] Reply-To — for the contact form, the sender's email, so a
  #   reply reaches the person who wrote in.
  # @raise [RuntimeError] when unconfigured.
  # @raise [ApplicationService::HttpError] on a non-2xx response.
  def send_email(to:, subject:, text:, html: nil, reply_to: nil)
    raise "Resend is not configured" unless configured?

    body = { from: @from, to: to, subject: subject, text: text }
    body[:html] = html if html.present?
    body[:reply_to] = reply_to if reply_to.present?

    post_json!(
      RESEND_API_URL,
      headers: {
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type" => "application/json"
      },
      body: body.to_json
    )
  end
end
