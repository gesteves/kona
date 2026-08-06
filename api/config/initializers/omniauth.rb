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
