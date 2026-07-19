require "uri"

module Api
  # Receives contact-form submissions from the public site. Reached through the web app's
  # same-origin Netlify proxy, which injects the API_TOKEN bearer (inherited gate on
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

    def create
      no_store!

      # Honeypot: a non-blank hidden field means a bot. Drop silently and answer exactly like a
      # success so the bot gets no signal that it was caught.
      return respond_success if params[HONEYPOT_FIELD].present?

      name = params[:name].to_s.strip
      email = params[:email].to_s.strip
      message = params[:message].to_s.strip

      return respond_error unless valid?(name, email, message)

      ContactMailJob.perform_async(name, email, message, client_ip, client_user_agent)
      respond_success
    end

    private

    # @return [Boolean] Whether the submission has a name, a message, and a well-formed email.
    def valid?(name, email, message)
      name.present? && message.present? && email.match?(URI::MailTo::EMAIL_REGEXP)
    end

    # The real visitor IP the web proxy forwards for Akismet (the origin can't see it — the
    # zone rewrites CF-Connecting-IP to the Netlify egress IP). Trusted only for spam scoring,
    # never for anything that bans.
    # @return [String, nil]
    def client_ip
      request.headers["X-Kona-Client-IP"].presence
    end

    # The real visitor User-Agent the web proxy forwards for Akismet.
    # @return [String, nil]
    def client_user_agent
      request.headers["X-Kona-Client-UA"].presence
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
