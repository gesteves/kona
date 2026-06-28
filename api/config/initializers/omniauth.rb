# Google OAuth for owner-only surfaces (/whoop/auth and the Sidekiq UI). Restricted to a single
# identity: `hd` makes the gem reject any login whose verified Google hosted domain isn't ours
# (server-side, on the id_token claim — @gmail.com accounts have no `hd` and are excluded), and
# SessionsController additionally pins the exact email. Both derive from OWNER_EMAIL so they
# can't drift. Blank credentials (dev/CI) are fine here — the provider only fails if exercised;
# specs use OmniAuth test mode.
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
