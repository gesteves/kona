require "httparty"

# Checks each contact-form submission with Akismet. Akismet returns a plain "true" or "false"
# body, and not JSON. Thus this class calls HTTParty directly, and not through the JSON methods.
#
# ⚠️ With a configuration, it fails **closed**: a failure of the service, or an answer that is not
# clear, raises. Thus the intake job runs again and does not deliver a message with no spam check.
# It fails open only with no configuration, which is the "Akismet off" state, on purpose.
#
# @see https://akismet.com/developers/comment-check/
class Akismet < ApplicationService
  # The API key is part of the request host of Akismet: https://<key>.rest.akismet.com/1.1/…
  AKISMET_API_HOST = "rest.akismet.com"

  # ⚠️ The key goes into a host name. A key with another character would send the request, with
  # the message and the visitor IP in it, to another host. A key outside this shape raises.
  API_KEY_FORMAT = /\A[a-z0-9-]+\z/i

  # @param api_key [String] The Akismet API key.
  # @param blog [String] The home URL of the site, which Akismet needs.
  def initialize(api_key: ENV["AKISMET_API_KEY"], blog: ENV["SITE_URL"])
    @api_key = api_key
    @blog = blog.to_s.chomp("/")
  end

  # @return [Boolean] True if both the key and the blog URL are available.
  def configured?
    @api_key.present? && @blog.present?
  end

  # Does a comment-check with Akismet.
  # @param content [String] The body of the message.
  # @param author [String, nil] The name of the sender.
  # @param author_email [String, nil] The email address of the sender.
  # @param user_ip [String, nil] The true visitor IP, which the web proxy sends. Akismet needs it.
  #   A blank value makes the answer less accurate.
  # @param user_agent [String, nil] The true visitor User-Agent, which the proxy also sends.
  # @return [Boolean] True if the submission is spam. It is false with no configuration.
  # @raise [ApplicationService::HttpError] If there is a configuration but Akismet gives no clear
  #   answer. Thus the next attempt of the caller does the check again and does not deliver a
  #   message with no check.
  def spam?(content:, author: nil, author_email: nil, user_ip: nil, user_agent: nil)
    return false unless configured?

    response = HTTParty.post(
      endpoint("comment-check"),
      body: comment_params(content, author, author_email, user_ip, user_agent),
      headers: { "Content-Type" => "application/x-www-form-urlencoded" }
    )

    verdict = response.body.to_s.strip

    # There is no clear answer, thus raise. The app must not deliver a message with no check.
    unless response.success? && %w[true false].include?(verdict)
      raise ApplicationService::HttpError.new(response.code, response.body, AKISMET_API_HOST)
    end

    verdict == "true"
  end

  # Tells Akismet that it marked a correct message as spam. Thus Akismet stops the mark on a sender
  # that the filter continues to catch. The code calls this when the owner sends a message from the
  # spam quarantine.
  #
  # ⚠️ This fails **soft**, which is the opposite of the rule of this class, on purpose. #spam?
  # raises, thus the app never delivers a message with no check. This method is for training, and a
  # failure in the training must never stop the delivery of a message that the owner already
  # accepted. The caller writes a log line and continues.
  #
  # @param (see #spam?)
  # @return [Boolean] True if Akismet accepted the submission. It is false with no configuration.
  # @see https://akismet.com/developers/submit-ham-false-positive/
  def submit_ham(content:, author: nil, author_email: nil, user_ip: nil, user_agent: nil)
    return false unless configured?

    response = HTTParty.post(
      endpoint("submit-ham"),
      body: comment_params(content, author, author_email, user_ip, user_agent),
      headers: { "Content-Type" => "application/x-www-form-urlencoded" }
    )

    response.success?
  end

  private

  # @param path [String] The name of the Akismet call.
  # @return [String] The URL of that call, with the key in the host.
  # @raise [ArgumentError] If the key cannot be part of a host name.
  def endpoint(path)
    raise ArgumentError, "AKISMET_API_KEY has an incorrect shape" unless @api_key.to_s.match?(API_KEY_FORMAT)

    "https://#{@api_key}.#{AKISMET_API_HOST}/1.1/#{path}"
  end

  # The comment fields that both endpoints take. The code removes each blank field.
  # @return [Hash]
  def comment_params(content, author, author_email, user_ip, user_agent)
    {
      blog: @blog,
      user_ip: user_ip,
      user_agent: user_agent,
      comment_type: "contact-form",
      comment_author: author,
      comment_author_email: author_email,
      comment_content: content
    }.compact
  end
end
