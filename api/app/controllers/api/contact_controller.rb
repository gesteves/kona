require "uri"

module Api
  # Takes the contact-form submissions from the public site, through the proxy of the web app, which
  # adds the bearer token. The Accept header decides the answer: a JSON caller gets a 204 or a 422,
  # and an HTML caller gets a 303 to the Thank-You page of the site. The spam check and the email
  # run in ContactMailJob, thus the request returns quickly.
  class ContactController < BaseController
    # This is a cross-origin POST. The bearer check from the parent class authenticates it, and not
    # a session.
    skip_forgery_protection

    # A hidden field. A person cannot see it, and a bot often writes a value in it.
    HONEYPOT_FIELD = :comment

    # The maximum lengths, thus nobody can post a very long text or make the Akismet payload and
    # the Resend payload large.
    MAX_NAME = 100
    MAX_EMAIL = 254 # RFC 5321 max
    MAX_MESSAGE = 5000

    def create
      no_store!

      # A honeypot field with a value means a bot. Answer as for a success, thus the bot learns
      # nothing.
      return respond_success if params[HONEYPOT_FIELD].present?

      name = params[:name].to_s.strip
      email = params[:email].to_s.strip
      message = params[:message].to_s.strip

      return respond_error unless valid?(name, email, message)

      # Turnstile protects the fetch path only, because its widget needs JavaScript. The path with
      # no JavaScript uses the honeypot, Akismet, and the rate limit.
      return respond_error if request.format.json? && !turnstile_ok?

      ContactMailJob.perform_async(name, email, message, sender_context)
      respond_success
    end

    private

    # @return [Boolean] True if the name, the email address, and the message are available and are
    #   not too long.
    def valid?(name, email, message)
      name.present? && name.length <= MAX_NAME &&
        message.present? && message.length <= MAX_MESSAGE &&
        email.length <= MAX_EMAIL && email.match?(URI::MailTo::EMAIL_REGEXP)
    end

    # @return [Boolean] True if the Turnstile token is correct, or if there is no Turnstile
    #   configuration.
    def turnstile_ok?
      Turnstile.new.verify(params[:"cf-turnstile-response"], remoteip: forwarded("X-Kona-Client-IP"))
    end

    # The true visitor data that the web proxy sends in its own headers, because the origin cannot
    # see it. The app uses it only for Akismet and for the Sender details of the email, and never for
    # a ban.
    # @return [Hash] A hash with string keys that Sidekiq can serialize. It has no blank value.
    def sender_context
      {
        "ip" => forwarded("X-Kona-Client-IP"),
        "user_agent" => forwarded("X-Kona-Client-UA"),
        "city" => forwarded("X-Kona-Client-City"),
        "region" => forwarded("X-Kona-Client-Region"),
        "country" => forwarded("X-Kona-Client-Country")
      }.compact
    end

    # @return [String, nil] A request header from the proxy, or nil if it is blank or absent.
    def forwarded(name)
      request.headers[name].presence
    end

    def respond_success
      if request.format.json?
        head :no_content
      else
        redirect_to "#{site_url}/contact/success", status: :see_other, allow_other_host: true
      end
    end

    def respond_error
      if request.format.json?
        render json: { error: "Please provide your name, a valid email address, and a message." }, status: :unprocessable_content
      else
        # The path with no JavaScript does not usually come here, because each field is `required`.
        # Thus this code sends the visitor back to the form and does not render a separate error
        # page.
        redirect_to "#{site_url}/contact", status: :see_other, allow_other_host: true
      end
    end

    def no_store!
      response.set_header("Cache-Control", "no-store")
    end

    def site_url
      ENV["SITE_URL"].to_s.chomp("/")
    end
  end
end
