# Writes a cycling FTP to the profile of the athlete on Strava. Api::FtpController adds it to the
# queue. The PUT sets one value, thus a retry is safe.
class StravaFtpJob < ApplicationJob
  # @param watts [Integer] The FTP in watts.
  # @raise [ApplicationJob::PermanentError] With no connection, with no `profile:write` scope, or
  #   when Strava ignores the value. A retry cannot correct any of them.
  def perform(watts)
    strava = Strava.new
    raise PermanentError, "Strava is not connected" unless strava.connected?

    saved = strava.update_athlete_ftp!(watts)
    raise PermanentError, "Strava ignored the FTP (sent #{watts} W, got #{saved.inspect})" unless saved == watts

    Rails.logger.info("FTP synced to Strava (#{watts} W)")
  rescue ApplicationService::HttpError => e
    raise unless [ 401, 403 ].include?(e.status)

    raise PermanentError, "Strava refused the FTP (HTTP #{e.status}). Reconnect Strava to grant profile:write."
  end
end
