require "httparty"

# Checks contact-form submissions against Akismet's spam-detection API. Used by ContactMailJob
# before it emails a submission to the owner. Returns a plain "true"/"false" body (spam/ham) —
# not JSON — so it calls HTTParty directly rather than through the JSON helpers.
#
# Fails **closed** when configured: if Akismet is down or returns no clean verdict, `spam?`
# **raises** so the intake job retries rather than delivering a message that was never spam-checked
# (we'd rather a submission wait in the retry/Dead-set queue than let spam through unchecked). It
# fails **open** only when unconfigured (no `AKISMET_API_KEY`) — that's a deliberate "Akismet off"
# state, so submissions are delivered. The honeypot + Turnstile are the always-on first lines of
# defense; this is the content check.
#
# @see https://akismet.com/developers/comment-check/
class Akismet < ApplicationService
  # Akismet keys the request host on the API key: https://<key>.rest.akismet.com/1.1/...
  AKISMET_API_HOST = "rest.akismet.com"

  # @param api_key [String] The Akismet API key.
  # @param blog [String] The front-page/home URL of the site the comment is for (Akismet's
  #   required `blog` param). Reuses the site URL the rest of the app already configures.
  def initialize(api_key: ENV["AKISMET_API_KEY"], blog: ENV["SITE_URL"])
    @api_key = api_key
    @blog = blog.to_s.chomp("/")
  end

  # @return [Boolean] Whether Akismet is configured enough to check (key + blog present).
  def configured?
    @api_key.present? && @blog.present?
  end

  # Runs a comment-check against Akismet.
  # @param content [String] The message body.
  # @param author [String, nil] The sender's name.
  # @param author_email [String, nil] The sender's email.
  # @param user_ip [String, nil] The real visitor IP (forwarded by the web proxy — the origin
  #   can't see it otherwise). Akismet requires it; a blank one just weakens the verdict.
  # @param user_agent [String, nil] The real visitor User-Agent (also proxy-forwarded).
  # @return [Boolean] true when Akismet classifies the submission as spam, false for ham (or when
  #   unconfigured — fail open).
  # @raise [ApplicationService::HttpError] when configured but Akismet is unreachable or returns
  #   no clean "true"/"false" verdict (transport errors propagate unchanged) — so the caller's
  #   Sidekiq retry re-checks rather than delivering an unchecked message.
  def spam?(content:, author: nil, author_email: nil, user_ip: nil, user_agent: nil)
    return false unless configured?

    body = {
      blog: @blog,
      user_ip: user_ip,
      user_agent: user_agent,
      comment_type: "contact-form",
      comment_author: author,
      comment_author_email: author_email,
      comment_content: content
    }.compact

    response = HTTParty.post(
      "https://#{@api_key}.#{AKISMET_API_HOST}/1.1/comment-check",
      body: body,
      headers: { "Content-Type" => "application/x-www-form-urlencoded" }
    )

    verdict = response.body.to_s.strip

    # No clean verdict (Akismet down/5xx, or an invalid-key "invalid" body with an
    # X-akismet-debug-help header): raise so the intake job retries. A message must not be
    # delivered without a real spam verdict.
    unless response.success? && %w[true false].include?(verdict)
      raise ApplicationService::HttpError.new(response.code, response.body, AKISMET_API_HOST)
    end

    verdict == "true"
  end
end
