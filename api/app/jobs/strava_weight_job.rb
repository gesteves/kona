# Writes a body weight to the profile of the athlete on Strava. Api::WeightController adds it to the
# queue. The PUT sets one value, thus a retry is safe.
class StravaWeightJob < ApplicationJob
  # @param kg [Float] The weight in kilograms.
  # @raise [ApplicationJob::PermanentError] With no connection, or with no `profile:write` scope. A
  #   retry cannot correct either one.
  def perform(kg)
    strava = Strava.new
    raise PermanentError, "Strava is not connected" unless strava.connected?

    strava.update_athlete_weight!(kg)
    Rails.logger.info("Weight synced to Strava (#{kg} kg)")
  rescue ApplicationService::HttpError => e
    raise unless [ 401, 403 ].include?(e.status)

    raise PermanentError, "Strava refused the weight (HTTP #{e.status}). Reconnect Strava to grant profile:write."
  end
end
