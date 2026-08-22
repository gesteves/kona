# Publishes one GPX track that a user uploaded to Mapbox, as a private vector tileset. It runs
# outside the upload request.
#
# The Mapbox Tiling Service publishes asynchronously and this job reads its status. Thus the job can
# hold a worker thread for as long as MapboxTileset::POLL_TIMEOUT. That is the reason that the upload
# does not do this work itself: the request budget is 20 seconds.
#
# This job is safe with the 24-hour retry from the parent class, because you can call
# MapboxTileset#create_from_coordinates! more than one time: the source upload replaces the source
# and does not add to it, a tileset that exists is a success, and a publish only makes a new job.
# ⚠️ The `kill_timeout` of fly is 30s, thus a deploy during a status read stops this job. Sidekiq
# puts the job in the queue again after a clean SIGTERM, and the next attempt completes it.
class MapTilesetJob < ApplicationJob
  # ⚠️ The code writes the status here, and not in a rescue in #perform. A mark of "failed" at the
  # first exception would change the record from failed to processing to failed at each attempt.
  # Thus "failed" here means that Sidekiq stopped after the last attempt.
  sidekiq_retries_exhausted do |msg, exception|
    id = msg["args"].first
    TrackLibrary.new.update(id, "status" => "failed", "error" => exception&.message.to_s.truncate(500))
    Rails.logger.error("Maps: giving up on tileset #{id} (#{exception&.class}: #{exception&.message})")
  end

  # @param id [String] The TrackLibrary record id.
  def perform(id)
    library = TrackLibrary.new
    record = library.find(id)
    return Rails.logger.info("Maps: track #{id} is gone; nothing to publish") if record.nil?
    return if record["status"] == "ready"

    coordinates = library.pending_coordinates(id)
    if coordinates.nil?
      library.update(id, "status" => "failed", "error" => "The upload expired before it could be published.")
      return Rails.logger.warn("Maps: no staged coordinates for track #{id}")
    end

    tileset_id = MapboxTileset.new.create_from_coordinates!(
      id: id,
      name: record["title"],
      coordinates: coordinates
    )

    library.update(id,
      "status" => "ready",
      "error" => nil,
      "tileset_id" => tileset_id,
      "source_layer" => MapboxTileset::LAYER_NAME,
      "published_at" => Time.now.utc.iso8601)
    library.discard_pending(id)

    Rails.logger.info("Maps: published tileset #{tileset_id}")
  end
end
