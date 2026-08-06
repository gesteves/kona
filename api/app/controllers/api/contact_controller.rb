require "uri"

module Api
  # Receives contact-form submissions from the public site, through the web app's proxy, which
  # injects the bearer. Answers by Accept: JSON callers get 204/422, HTML callers get a 303 to
  # the site's Thank-You page. The spam check and email run in ContactMailJob so the request
  # returns fast.
  class ContactController < BaseController
    # This is a cross-origin POST authenticated by the inherited bearer check, not a session.
    skip_forgery_protection

    # A hidden field, invisible to humans and commonly filled by bots.
    HONEYPOT_FIELD = :comment

    # Length caps, so nobody can post a novel or bloat the Akismet and Resend payloads.
    MAX_NAME = 100
    MAX_EMAIL = 254 # RFC 5321 max
    MAX_MESSAGE = 5000

    def create
      no_store!

      # A filled honeypot means a bot. Answer exactly like a success, so it gets no signal.
      return respond_success if params[HONEYPOT_FIELD].present?

      name = params[:name].to_s.strip
      email = params[:email].to_s.strip
      message = params[:message].to_s.strip

      return respond_error unless valid?(name, email, message)

      # Turnstile only guards the fetch path, since its widget needs JS. The no-JS path falls
      # back to the honeypot, Akismet, and the rate limit.
      return respond_error if request.format.json? && !turnstile_ok?

      ContactMailJob.perform_async(name, email, message, sender_context)
      respond_success
    end

    private

    # @return [Boolean] Whether the name, email, and message are present and in bounds.
    def valid?(name, email, message)
      name.present? && name.length <= MAX_NAME &&
        message.present? && message.length <= MAX_MESSAGE &&
        email.length <= MAX_EMAIL && email.match?(URI::MailTo::EMAIL_REGEXP)
    end

    # @return [Boolean] Whether the Turnstile token passes, or Turnstile is unconfigured.
    def turnstile_ok?
      Turnstile.new.verify(params[:"cf-turnstile-response"], remoteip: forwarded("X-Kona-Client-IP"))
    end

    # The real visitor signal the web proxy forwards under custom headers, since the origin
    # can't see it otherwise. Trusted only for Akismet and the email's Sender details, never for
    # anything that bans.
    # @return [Hash] A string-keyed, Sidekiq-serializable hash, with blanks dropped.
    def sender_context
      {
        "ip" => forwarded("X-Kona-Client-IP"),
        "user_agent" => forwarded("X-Kona-Client-UA"),
        "city" => forwarded("X-Kona-Client-City"),
        "region" => forwarded("X-Kona-Client-Region"),
        "country" => forwarded("X-Kona-Client-Country")
      }.compact
    end

    # @return [String, nil] A proxy-forwarded request header, or nil when blank or absent.
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
        # The no-JS path can't normally reach here, since the fields are `required`, so this
        # just sends them back to the form rather than rendering a bespoke error page.
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
