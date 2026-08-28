# Does a Whoop token refresh on a schedule (refer to config/sidekiq.yml), thus the app continues to
# use the refresh token, which rotates. In all other conditions, a refresh occurs only when it is
# necessary: a /widgets/whoop request that is not in the edge cache, or a webhook. Thus a period with
# no traffic and no workout leaves the refresh token with no use until Whoop makes it expire, and
# only a manual authorization at /whoop/auth then corrects that.
#
# ⚠️ A refresh that fails does NOT raise again, on purpose. Whoop#refresh_access_token already writes
# it to the log and sends it to Bugsnag, and the next run of this job is the next attempt. A raise
# would use the 24-hour window of the parent class to POST a token that Whoop already removed.
class WhoopTokenRefreshJob < ApplicationJob
  def perform
    whoop = Whoop.new
    return unless whoop.valid_credentials? && whoop.connected?

    if whoop.refresh_tokens!.present?
      # The label of the Connected apps page. This covers a connection from before the app stored
      # it, thus no person has to authorize again to see which account is connected.
      whoop.store_account_email! if whoop.account_email.blank?
      Rails.logger.info("Whoop access token refreshed on schedule")
    else
      Rails.logger.warn("Scheduled Whoop token refresh failed. Visit /whoop/auth to re-authorize.")
    end
  end
end
