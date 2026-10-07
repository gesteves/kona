# Writes a cycling FTP to the profile of the athlete on Strava. Api::FtpController adds it to the
# queue. Each PUT sets the same value, thus a retry is safe.
class StravaFtpJob < ApplicationJob
  # @param watts [Integer] The FTP in watts.
  # @raise [ApplicationJob::PermanentError] With no connection, or with no `profile:write` scope. A
  #   retry cannot correct either one.
  def perform(watts)
    strava = Strava.new
    raise PermanentError, "Strava is not connected" unless strava.connected?

    strava.update_athlete_ftp!(watts)
    Rails.logger.info("FTP synced to Strava (#{watts} W)")
  rescue ApplicationService::HttpError => e
    raise unless [ 401, 403 ].include?(e.status)

    raise PermanentError, "Strava refused the FTP (HTTP #{e.status}). Reconnect Strava to grant profile:write."
  end
end
