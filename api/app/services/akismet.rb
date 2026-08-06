require "httparty"

# Checks contact-form submissions against Akismet. Returns a plain "true"/"false" body rather
# than JSON, so it calls HTTParty directly instead of through the JSON helpers.
#
# ⚠️ Fails **closed** when configured: an outage or unclear verdict raises, so the intake job
# retries rather than delivering a message that was never spam-checked. It fails open only when
# unconfigured, which is a deliberate "Akismet off" state.
#
# @see https://akismet.com/developers/comment-check/
class Akismet < ApplicationService
  # Akismet keys the request host on the API key: https://<key>.rest.akismet.com/1.1/…
  AKISMET_API_HOST = "rest.akismet.com"

  # @param api_key [String] The Akismet API key.
  # @param blog [String] The site's home URL, which Akismet requires.
  def initialize(api_key: ENV["AKISMET_API_KEY"], blog: ENV["SITE_URL"])
    @api_key = api_key
    @blog = blog.to_s.chomp("/")
  end

  # @return [Boolean] Whether both the key and the blog URL are present.
  def configured?
    @api_key.present? && @blog.present?
  end

  # Runs a comment-check against Akismet.
  # @param content [String] The message body.
  # @param author [String, nil] The sender's name.
  # @param author_email [String, nil] The sender's email.
  # @param user_ip [String, nil] The real visitor IP, forwarded by the web proxy. Akismet wants
  #   it; a blank one only weakens the verdict.
  # @param user_agent [String, nil] The real visitor User-Agent, also proxy-forwarded.
  # @return [Boolean] Whether the submission is spam. False when unconfigured.
  # @raise [ApplicationService::HttpError] when configured but Akismet gives no clean verdict,
  #   so the caller's retry re-checks rather than delivering an unchecked message.
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

    # No clean verdict, so raise: a message must not be delivered unchecked.
    unless response.success? && %w[true false].include?(verdict)
      raise ApplicationService::HttpError.new(response.code, response.body, AKISMET_API_HOST)
    end

    verdict == "true"
  end
end
