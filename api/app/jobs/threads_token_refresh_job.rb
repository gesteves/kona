# Gets a new 60-day Threads token each day (refer to config/sidekiq.yml).
#
# ⚠️ This job is what keeps the connection. A Threads token expires 60 days after the app got it,
# there is no refresh token, and an expired token is dead for all time: only a new authorization in
# the admin corrects that. Thus the app must refresh the token before that day, whether or not any
# code reads the account.
#
# ⚠️ A refresh that fails does NOT raise, on purpose. Threads#refresh! already writes it to the log,
# sends it to Bugsnag, and records a 4xx for the Connected apps page. The next run of this job is
# the next attempt, and the window is 60 days wide. A raise would use the 24-hour retry of the
# parent class against an endpoint that refuses a token which is less than 24 hours old.
class ThreadsTokenRefreshJob < ApplicationJob
  def perform
    case Threads.new.refresh!
    when :refreshed then Rails.logger.info("Threads access token refreshed on schedule")
    when :too_soon  then Rails.logger.info("Threads access token is too new to refresh; trying again tomorrow")
    when :failed    then Rails.logger.warn("Scheduled Threads token refresh failed. Reconnect on the Connected apps page.")
    end
  end
end
