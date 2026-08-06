require "httparty"

# Sends transactional email through the Resend HTTP API, which works from fly — an HTTPS call,
# where outbound SMTP is blocked — and needs only SPF/DKIM, so it coexists with a Google
# Workspace mailbox on the same domain without touching the root MX.
#
# @see https://resend.com/docs/api-reference/emails/send-email
class Resend < ApplicationService
  RESEND_API_URL = "https://api.resend.com/emails"

  # @param api_key [String] The Resend API key.
  # @param from [String] The sender address, on a domain verified in Resend.
  def initialize(api_key: ENV["RESEND_API_KEY"], from: ENV["CONTACT_FROM_ADDRESS"])
    @api_key = api_key
    @from = from
  end

  # @return [Boolean] Whether the key and sender address are both present.
  def configured?
    @api_key.present? && @from.present?
  end

  # Sends an email.
  # @param to [String] The recipient.
  # @param subject [String] The subject line.
  # @param text [String] The plain-text body, always sent, for deliverability.
  # @param html [String, nil] An HTML body.
  # @param reply_to [String, nil] The Reply-To address.
  # @raise [RuntimeError] when unconfigured.
  # @raise [ApplicationService::HttpError] on a non-2xx, so the caller's retry picks it up.
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
