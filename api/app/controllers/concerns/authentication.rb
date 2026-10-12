# The owner-session check that each controller and each view for the site owner shares. A successful
# Google sign-in, in SessionsController, puts the email address of the owner in the signed cookie
# session. Each method here compares that value with OWNER_EMAIL. A separate Rack guard controls the
# Sidekiq UI (refer to config/initializers/sidekiq.rb), because that UI is not a Rails controller.
module Authentication
  extend ActiveSupport::Concern

  # The longest time that one sign-in lasts. ⚠️ The `expire_after` of the session store is not this
  # limit: Rack writes the cookie again at each request with a new expiry, thus that value is an
  # idle limit only.
  MAX_SESSION_AGE = 2.weeks

  # The one owner check. The controllers and the Rack guard of the Sidekiq UI both call it.
  # @param session [ActionDispatch::Request::Session, Hash, nil] The session of the request.
  # @return [Boolean] True when the session belongs to the owner in the configuration, and the
  #   sign-in is not older than MAX_SESSION_AGE.
  def self.owner_session?(session)
    owner = ENV["OWNER_EMAIL"].to_s
    return false if owner.blank? || session.nil?
    return false unless session["owner_email"].present? && session["owner_email"] == owner

    signed_in_at = session["signed_in_at"]
    signed_in_at.is_a?(Integer) && Time.zone.at(signed_in_at) > MAX_SESSION_AGE.ago
  end

  private

  # @return [Boolean] True when the session belongs to the owner in the configuration.
  def owner_signed_in?
    Authentication.owner_session?(session)
  end

  # Redirects to the login page when the owner is not signed in. It keeps the path that they wanted,
  # for a GET request only, thus the callback can send them there.
  def require_owner!
    return if owner_signed_in?

    session[:return_to] = request.fullpath if request.get? || request.head?
    redirect_to "/signin"
  end
end
