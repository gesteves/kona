# Owner authentication via Google OAuth. Gates /whoop/auth and the Sidekiq UI down to a single
# identity: the OmniAuth provider's `hd` already rejects logins outside our Google hosted domain;
# #create additionally pins the exact OWNER_EMAIL and requires a verified email. A successful
# sign-in stores the owner email in the signed cookie session; Authentication#owner_signed_in?
# (and the Sidekiq Rack guard) check it.
class SessionsController < ActionController::Base
  layout false

  # The OmniAuth request phase (POST /auth/google_oauth2) is CSRF-protected by
  # omniauth-rails_csrf_protection; the callback is a GET redirect from Google.

  # GET /login
  def new
  end

  # GET /auth/google_oauth2/callback
  def create
    auth = request.env["omniauth.auth"]
    email = auth&.dig("info", "email")
    verified = auth&.dig("extra", "raw_info", "email_verified")
    owner = ENV["OWNER_EMAIL"].to_s

    if owner.present? && email.present? && email == owner && verified.to_s == "true"
      destination = safe_return_path(session[:return_to])
      reset_session # guard against session fixation (after reading return_to above)
      session[:owner_email] = email
      redirect_to(destination)
    else
      Rails.logger.warn("Owner auth rejected: email=#{email.inspect} verified=#{verified.inspect}")
      render plain: "Not authorized.", status: :forbidden
    end
  end

  # GET /auth/failure
  def failure
    render plain: "Sign-in failed (#{params[:message]}).", status: :unauthorized
  end

  # POST /logout
  def destroy
    reset_session
    redirect_to "/login"
  end

  private

  # The path stashed by Authentication#require_owner!, or the Sidekiq dashboard by default. Only
  # accept a relative path (leading "/" but not "//") so a stale/forged value can't open-redirect.
  def safe_return_path(path)
    path.present? && path.start_with?("/") && !path.start_with?("//") ? path : "/sidekiq"
  end
end
