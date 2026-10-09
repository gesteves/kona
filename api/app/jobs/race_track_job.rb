# Adds the GPS track of one race leg to the Course maps page, as an upload of its GPX would.
# ActivityDescription::Generator adds it to the queue when it finds a leg.
#
# The GPX comes from Intervals.icu, and Intervals.icu refuses an activity that came from Strava.
# Thus no Strava data goes into the track.
class RaceTrackJob < ApplicationJob
  # Intervals.icu gave no GPX. The retry of ApplicationJob tries again.
  class GpxUnavailable < StandardError; end

  # @param activity_id [String] The Intervals.icu activity id.
  # @param name [String] The name of the leg, for example "<race> – Bike".
  # @param sport [String] The standard sport of ActivityMatcher, for example "Cycling".
  def perform(activity_id, name, sport)
    gpx = Intervals.new.activity_gpx(activity_id)
    raise GpxUnavailable, "Intervals.icu gave no GPX for activity #{activity_id}" if gpx.nil?

    track = GpxTrack.new(StringIO.new(gpx), name: name, type: sport)
    library = TrackLibrary.new
    # ⚠️ The id comes from the title. Thus a track with that id is the same race, and it can have
    # render settings from the owner.
    return Rails.logger.info("Maps: track #{track.id} exists; activity #{activity_id} adds nothing") if library.find(track.id)

    MapTilesetJob.perform_async(library.stage(track))
    Rails.logger.info("Maps: added #{track.title.inspect} from activity #{activity_id}")
  rescue GpxTrack::ParseError => e
    Rails.logger.warn("Maps: could not read the GPX of activity #{activity_id} (#{e.message})")
  end
end
