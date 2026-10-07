# Corrects the Rouvy name of a Strava activity, with no Intervals.icu data. StravaActivityJob adds it
# to the queue when Intervals.icu never gets the activity, thus ActivityDescriptionJob never runs.
# The PUT sets one value, thus a retry is safe.
class StravaNameJob < ApplicationJob
  # @param strava_id [String] The Strava activity id.
  def perform(strava_id)
    strava = Strava.new
    unless strava.connected?
      Rails.logger.info("Strava activity #{strava_id}: Strava is not connected — no rename")
      return
    end

    current = strava.activity(strava_id)
    name = ActivityDescription::Composer.clean_name(current[:name])
    return if name.blank? || name == current[:name]

    strava.update_activity!(strava_id, name: name)
    Rails.logger.info("Strava activity #{strava_id}: renamed to #{name.inspect}")
  end
end
