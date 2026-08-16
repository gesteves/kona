# Publishes one uploaded GPX track to Mapbox as a private vector tileset, off the upload request.
#
# The Mapbox Tiling Service publishes asynchronously and this polls it, so the job can hold a
# worker thread for up to MapboxTileset::POLL_TIMEOUT. That's the whole reason the upload doesn't
# do this inline — the request budget is 20 seconds.
#
# Safe under the inherited 24-hour retry because MapboxTileset#create_from_coordinates! is
# idempotent: the source upload replaces rather than appends, an existing tileset counts as
# success, and publishing just mints a new job. ⚠️ fly's `kill_timeout` is 30s, so a deploy
# landing mid-poll kills this; Sidekiq re-enqueues on a clean SIGTERM and the retry finishes it.
class MapTilesetJob < ApplicationJob
  # ⚠️ The status is written here rather than in a rescue inside #perform. Marking a record failed
  # on the first exception would have it flicker failed → processing → failed on every retry, so
  # "failed" means Sidekiq has genuinely given up.
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
