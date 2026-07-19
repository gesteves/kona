require "httparty"

# Checks contact-form submissions against Akismet's spam-detection API. Used by ContactMailJob
# before it emails a submission to the owner. Returns a plain "true"/"false" body (spam/ham) —
# not JSON — so it calls HTTParty directly rather than through the JSON helpers.
#
# Fails open: any misconfiguration or upstream error returns "not spam" so a legitimate message
# is never silently lost to an Akismet hiccup (a bit of spam slipping through is the safer
# failure). The honeypot is the always-on first line of defense; this is the content check.
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
  # @return [Boolean] true when Akismet classifies the submission as spam; false otherwise
  #   (including when unconfigured or on any error — fail open).
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

    # An invalid key / malformed request answers with something other than "true"/"false"
    # (and an X-akismet-debug-help header). Treat anything that isn't an explicit "true" as
    # ham so we fail open.
    unless response.success? && %w[true false].include?(response.body.to_s.strip)
      report_upstream_error("Akismet unexpected response", status: response.code)
      return false
    end

    response.body.to_s.strip == "true"
  rescue StandardError => e
    report_upstream_error(e)
    false
  end
end
