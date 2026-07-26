require "httparty"

# Verifies Cloudflare Turnstile tokens via the siteverify API. Used by Api::ContactController to
# confirm a contact-form submission passed the client-side challenge. Tokens are single-use and
# expire after 300s, so verification happens in the request path (not the delayed job).
#
# Fails OPEN when TURNSTILE_SECRET is unset (like Akismet), so dev/local and a not-yet-configured
# deploy still work; when a secret is present, a missing or explicitly-invalid token is rejected. A
# transport error (we have a token but can't reach siteverify) also fails open — the submission
# already passed a challenge, and honeypot + Akismet + the rate limit still guard.
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
  # @param token [String, nil] The token from the client widget (cf-turnstile-response).
  # @param remoteip [String, nil] The real visitor IP (optional; improves accuracy).
  # @return [Boolean] true when the token is valid — or when unconfigured (fail open). false for a
  #   blank or explicitly-invalid token.
  def verify(token, remoteip: nil)
    return true unless configured?
    return false if token.blank?

    body = { secret: @secret, response: token }
    body[:remoteip] = remoteip if remoteip.present?

    # The timeout is what makes the fail-open real: without it Net::HTTP waits its 60s defaults,
    # so a *hung* (rather than refused) siteverify holds the contact request until rack-timeout
    # kills the thread — a 500 to the visitor instead of the accept below. A timeout raises
    # Net::OpenTimeout/ReadTimeout, which the rescue turns into the intended open failure.
    response = HTTParty.post(SITEVERIFY_URL, body: body, timeout: 5)
    unless response.success?
      # Transport/API error: we have a token (a challenge was attempted) but can't confirm it.
      # Fail open rather than block a real user during a Cloudflare hiccup.
      report_upstream_error("Turnstile HTTP #{response.code}", status: response.code)
      return true
    end

    JSON.parse(response.body, symbolize_names: true)[:success] == true
  rescue StandardError => e
    report_upstream_error(e)
    true
  end
end
