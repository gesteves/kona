# Forces a Whoop token refresh on a schedule (see config/sidekiq.yml) so the rotating refresh
# token keeps being exercised. Tokens are otherwise only refreshed on demand — by a /widgets/whoop
# request that misses the edge cache, or by an inbound webhook — so a stretch with no traffic and
# no workouts leaves the refresh token idle until Whoop expires it, recoverable only by a manual
# re-auth at /whoop/auth.
#
# ⚠️ A failed refresh is deliberately NOT re-raised. Whoop#refresh_access_token already logs it and
# reports to Bugsnag, and the next tick is the retry — raising would spend the inherited 24-hour
# window re-POSTing a token Whoop has already revoked.
class WhoopTokenRefreshJob < ApplicationJob
  def perform
    whoop = Whoop.new
    return unless whoop.valid_credentials? && whoop.connected?

    if whoop.refresh_tokens!.present?
      Rails.logger.info("Whoop access token refreshed on schedule")
    else
      Rails.logger.warn("Scheduled Whoop token refresh failed. Visit /whoop/auth to re-authorize.")
    end
  end
end
