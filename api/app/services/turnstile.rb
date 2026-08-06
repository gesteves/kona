require "httparty"

# Verifies Cloudflare Turnstile tokens via siteverify, confirming a contact-form submission
# passed the client-side challenge. Tokens are single-use and expire after 300s, so this runs in
# the request path rather than the delayed job.
#
# Fails open when unconfigured, and on a transport error — the submission already passed a
# challenge, and the honeypot, Akismet, and the rate limit still guard. A missing or
# explicitly-invalid token is rejected.
#
# @see https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
class Turnstile < ApplicationService
  SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  # @param secret [String] The Turnstile secret key.
  def initialize(secret: ENV["TURNSTILE_SECRET"])
    @secret = secret
  end

  # @return [Boolean] Whether verification is configured (a secret is present).
  def configured?
    @secret.present?
  end

  # Verifies a Turnstile response token.
  # @param token [String, nil] The token from the client widget.
  # @param remoteip [String, nil] The real visitor IP; improves accuracy.
  # @return [Boolean] Whether the token is valid. True when unconfigured or unreachable.
  def verify(token, remoteip: nil)
    return true unless configured?
    return false if token.blank?

    body = { secret: @secret, response: token }
    body[:remoteip] = remoteip if remoteip.present?

    # The timeout is what makes the fail-open real: without it a hung siteverify would hold the
    # request until rack-timeout kills the thread, 500ing the visitor instead of accepting.
    response = HTTParty.post(SITEVERIFY_URL, body: body, timeout: 5)
    unless response.success?
      # A challenge was attempted but can't be confirmed; don't block a real user over it.
      report_upstream_error("Turnstile HTTP #{response.code}", status: response.code)
      return true
    end

    JSON.parse(response.body, symbolize_names: true)[:success] == true
  rescue StandardError => e
    report_upstream_error(e)
    true
  end
end
