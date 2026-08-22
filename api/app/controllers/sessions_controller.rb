# The owner authentication, with Google OAuth. It limits /whoop/auth and the Sidekiq UI to one
# identity. The `hd` value of the OmniAuth provider already refuses a login outside our Google hosted
# domain, and #create also tests the exact OWNER_EMAIL and needs an email that Google verified. A
# successful sign-in puts the owner email in the signed cookie session.
# Authentication#owner_signed_in?, and the Sidekiq Rack guard, read it.
class SessionsController < ActionController::Base
  # The sign-in page is the one page for the owner that a visitor can reach with no session. Thus it
  # is the page that needs the noindex header.
  include OwnerFacing

  # Only #new renders a page. #create, #failure, and #destroy each redirect or do a `render plain:`,
  # and a plain render uses no layout.
  layout "auth"

  # omniauth-rails_csrf_protection gives CSRF protection to the OmniAuth request phase, which is
  # POST /auth/google_oauth2. The callback is a GET redirect from Google.

  # GET /signin
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

  # POST /signout
  def destroy
    reset_session
    # Use a 303, thus Turbo follows the redirect with a GET and does not send the POST again.
    redirect_to "/signin", status: :see_other
  end

  private

  # The path that Authentication#require_owner! stored, or, by default, the admin home page, which
  # is the root of this host. It accepts a relative path only, that is, a path that starts with "/"
  # but not with "//". Thus an old value, or a value that an attacker writes, cannot send the browser
  # to another site.
  def safe_return_path(path)
    path.present? && path.start_with?("/") && !path.start_with?("//") ? path : "/"
  end
end
