# The Google OAuth for the pages of the owner only, for one identity. `hd` refuses each login whose
# verified hosted domain is not ours, on the server, from the id_token claim. SessionsController
# also tests the exact email address. Both come from OWNER_EMAIL, thus they always agree. Blank
# credentials are acceptable in development and in CI, because the provider fails only when
# something uses it.
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

# ⚠️ This code lets a person sign in with no check, and only this condition keeps it out of
# production. In the test mode of OmniAuth, the request phase never reaches Google: POST
# /auth/google_oauth2 redirects directly to the callback with the hash below. Thus /signin
# authenticates as OWNER_EMAIL against nothing. The code needs both conditions. Thus a
# `DEV_OWNER_SIGNIN` by error in a deployed environment is not sufficient, and a RAILS_ENV error on
# your own machine is not sufficient. SessionsController also tests the email address, thus an
# OWNER_EMAIL with no value refuses the sign-in and does not sign in as nobody.
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
