require "httparty"

# Sends an email through the Resend HTTP API. That API works from fly, because it is an HTTPS call
# and fly blocks outbound SMTP. It needs only SPF and DKIM, thus it works with a Google Workspace
# mailbox on the same domain and it does not change the root MX record.
#
# @see https://resend.com/docs/api-reference/emails/send-email
class Resend < ApplicationService
  RESEND_API_URL = "https://api.resend.com/emails"

  # @param api_key [String] The Resend API key.
  # @param from [String] The sender address, on a domain that Resend verified.
  def initialize(api_key: ENV["RESEND_API_KEY"], from: ENV["CONTACT_FROM_ADDRESS"])
    @api_key = api_key
    @from = from
  end

  # @return [Boolean] True if the key and the sender address are both available.
  def configured?
    @api_key.present? && @from.present?
  end

  # Sends an email.
  # @param to [String] The address of the receiver.
  # @param subject [String] The subject line.
  # @param text [String] The plain-text body. The code always sends it, for better delivery.
  # @param html [String, nil] An HTML body.
  # @param reply_to [String, nil] The Reply-To address.
  # @raise [RuntimeError] If there is no configuration.
  # @raise [ApplicationService::HttpError] If the response is not a 2xx, thus the caller does the
  #   send again.
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
