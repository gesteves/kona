# The owner-session check that each controller and each view for the site owner shares. A successful
# Google sign-in, in SessionsController, puts the email address of the owner in the signed cookie
# session. Each method here compares that value with OWNER_EMAIL. A separate Rack guard controls the
# Sidekiq UI (refer to config/initializers/sidekiq.rb), because that UI is not a Rails controller.
module Authentication
  extend ActiveSupport::Concern

  private

  # @return [Boolean] True when the session belongs to the owner in the configuration.
  def owner_signed_in?
    owner = ENV["OWNER_EMAIL"].to_s
    owner.present? && session[:owner_email].present? && session[:owner_email] == owner
  end

  # Redirects to the login page when the owner is not signed in. It keeps the path that they wanted,
  # for a GET request only, thus the callback can send them there.
  def require_owner!
    return if owner_signed_in?

    session[:return_to] = request.fullpath if request.get? || request.head?
    redirect_to "/signin"
  end
end
