# Google OAuth for the owner-only surfaces, restricted to a single identity: `hd` rejects any
# login whose verified hosted domain isn't ours, server-side on the id_token claim, and
# SessionsController additionally pins the exact email. Both derive from OWNER_EMAIL, so they
# can't drift. Blank credentials are fine in dev and CI — the provider only fails if exercised.
OmniAuth.config.logger = Rails.logger

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
    ENV["GOOGLE_OAUTH_CLIENT_ID"],
    ENV["GOOGLE_OAUTH_CLIENT_SECRET"],
    {
      scope: "email",
      hd: ENV["OWNER_EMAIL"].to_s.split("@").last.presence,
      prompt: "select_account"
    }
end

# ⚠️ A sign-in bypass, and the only thing keeping it out of production is this guard. In OmniAuth's
# test mode the request phase never reaches Google: POST /auth/google_oauth2 redirects straight to
# the callback carrying the hash below, so /signin authenticates as OWNER_EMAIL against nothing.
# Both conditions are required, so neither a stray `DEV_OWNER_SIGNIN` in a deployed environment nor
# a local RAILS_ENV mistake is enough on its own — and SessionsController still pins the email, so
# an unset OWNER_EMAIL fails closed rather than signing in as nobody.
if Rails.env.development? && ENV["DEV_OWNER_SIGNIN"].present?
  Rails.logger.warn("⚠️ DEV_OWNER_SIGNIN: /signin authenticates as #{ENV['OWNER_EMAIL'].inspect} without Google.")

  OmniAuth.config.test_mode = true
  OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
    provider: "google_oauth2",
    uid: "dev-owner",
    info: { email: ENV["OWNER_EMAIL"] },
    extra: { raw_info: { email_verified: "true" } }
  )
end
