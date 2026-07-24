require "uri"

module Api
  # Receives contact-form submissions from the public site. Reached through the web app's
  # same-origin proxy, which injects the API_TOKEN bearer (inherited gate on
  # BaseController), so direct/public hits get a cheap 401. Accepts either a JSON body (the
  # progressive-enhancement `fetch`) or a urlencoded/multipart body (the no-JS native form
  # POST), and answers accordingly: JSON callers get 204/422; HTML callers get a 303 redirect
  # to the site's Thank-You page. The actual spam-check + email happen in ContactMailJob so the
  # request returns fast.
  class ContactController < BaseController
    # The bearer check is inherited from BaseController; only forgery protection (this is a
    # cross-origin POST authenticated by the bearer, not a Rails session) needs skipping.
    skip_forgery_protection

    # Hidden honeypot field — invisible to humans (CSS), commonly filled by bots.
    HONEYPOT_FIELD = :comment

    # Server-side length caps, so nobody can post a novel or bloat the Akismet/Resend payloads.
    MAX_NAME = 100
    MAX_EMAIL = 254 # RFC 5321 max
    MAX_MESSAGE = 5000

    def create
      no_store!

      # Honeypot: a non-blank hidden field means a bot. Drop silently and answer exactly like a
      # success so the bot gets no signal that it was caught.
      return respond_success if params[HONEYPOT_FIELD].present?

      name = params[:name].to_s.strip
      email = params[:email].to_s.strip
      message = params[:message].to_s.strip

      return respond_error unless valid?(name, email, message)

      # Turnstile guards the JS/fetch path (the widget needs JS; tokens are single-use + 300s, so
      # verify here, not in the delayed job). The no-JS HTML path falls back to honeypot + Akismet
      # + the rack-attack rate limit. The service fails open when TURNSTILE_SECRET is unset.
      return respond_error if request.format.json? && !turnstile_ok?

      ContactMailJob.perform_async(name, email, message, sender_context)
      respond_success
    end

    private

    # @return [Boolean] Whether the submission has a well-formed, in-bounds name, email, and message.
    def valid?(name, email, message)
      name.present? && name.length <= MAX_NAME &&
        message.present? && message.length <= MAX_MESSAGE &&
        email.length <= MAX_EMAIL && email.match?(URI::MailTo::EMAIL_REGEXP)
    end

    # @return [Boolean] Whether the Turnstile token passes (or Turnstile isn't configured).
    def turnstile_ok?
      Turnstile.new.verify(params[:"cf-turnstile-response"], remoteip: forwarded("X-Kona-Client-IP"))
    end

    # Real visitor signal the web proxy forwards under custom headers (the origin can't see it —
    # the zone rewrites the CF-* headers to describe the proxy's PoP, not the visitor). Trusted only
    # for Akismet + the email's Sender details, never for anything that bans. Passed to the job as a
    # plain string-keyed hash (Sidekiq-serializable); blanks are dropped.
    # @return [Hash]
    def sender_context
      {
        "ip" => forwarded("X-Kona-Client-IP"),
        "user_agent" => forwarded("X-Kona-Client-UA"),
        "city" => forwarded("X-Kona-Client-City"),
        "region" => forwarded("X-Kona-Client-Region"),
        "country" => forwarded("X-Kona-Client-Country")
      }.compact
    end

    # @return [String, nil] A proxy-forwarded request header, or nil when blank/absent.
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
        # The no-JS path normally can't reach here (the fields are `required`), so just send them
        # back to the form rather than rendering a bespoke error page.
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
