require "httparty"

# Checks a Cloudflare Turnstile token with siteverify, to know that a contact-form submission passed
# the challenge in the browser. A token works one time and it expires after 300s, thus this code
# runs in the request path and not in the job.
#
# It permits the submission when there is no configuration and after a transport error, because the
# submission already passed a challenge and the honeypot, Akismet, and the rate limit still protect
# the form. It refuses a token that is absent, and a token that Turnstile says is incorrect.
#
# @see https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
class Turnstile < ApplicationService
  SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  # @param secret [String] The Turnstile secret key.
  def initialize(secret: ENV["TURNSTILE_SECRET"])
    @secret = secret
  end

  # @return [Boolean] True if the check has a configuration, that is, a secret is available.
  def configured?
    @secret.present?
  end

  # Checks a Turnstile response token.
  # @param token [String, nil] The token from the widget in the browser.
  # @param remoteip [String, nil] The true visitor IP. It makes the result more accurate.
  # @return [Boolean] True if the token is correct. It is also true when there is no configuration
  #   and when the code cannot reach Turnstile.
  def verify(token, remoteip: nil)
    return true unless configured?
    return false if token.blank?

    body = { secret: @secret, response: token }
    body[:remoteip] = remoteip if remoteip.present?

    # The timeout is what makes this code permit the submission after a failure. Without it, a
    # siteverify that stops would hold the request until rack-timeout stops the thread, and the
    # visitor would get a 500 in place of an acceptance.
    response = HTTParty.post(SITEVERIFY_URL, body: body, timeout: 5)
    unless response.success?
      # The browser did a challenge but this code cannot confirm it. Do not stop a true user for
      # that.
      report_upstream_error("Turnstile HTTP #{response.code}", status: response.code)
      return true
    end

    JSON.parse(response.body, symbolize_names: true)[:success] == true
  rescue StandardError => e
    report_upstream_error(e)
    true
  end
end
