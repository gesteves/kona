# Owner-session gating shared by the controllers and views that must be restricted to the site
# owner. A successful Google sign-in (SessionsController) stores the owner's email in the signed
# cookie session; everything here just checks it against OWNER_EMAIL. The Sidekiq UI is gated
# separately by a Rack guard (config/initializers/sidekiq.rb) since it isn't a Rails controller.
module Authentication
  extend ActiveSupport::Concern

  private

  # @return [Boolean] true when the session belongs to the configured owner.
  def owner_signed_in?
    owner = ENV["OWNER_EMAIL"].to_s
    owner.present? && session[:owner_email].present? && session[:owner_email] == owner
  end

  # Redirects to the login page unless the owner is signed in, remembering where they were
  # headed (GET requests only) so the callback can send them back.
  def require_owner!
    return if owner_signed_in?

    session[:return_to] = request.fullpath if request.get? || request.head?
    redirect_to "/login"
  end
end
