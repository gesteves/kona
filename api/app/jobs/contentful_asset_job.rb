# Makes one published Contentful asset from a file that the owner picked on the media uploader.
#
# The bytes already went to Contentful in the request, as an Upload. This job does the three steps
# that stay: it creates the asset with its title and its description, it processes the file, and it
# publishes the result.
#
# Contentful processes a file asynchronously, thus this job can hold a worker thread for as long as
# ContentfulManagement::POLL_TIMEOUT. That is the reason that the submit does not do this work
# itself: the request budget is 20 seconds.
# ⚠️ The `kill_timeout` of fly is 30s, thus a deploy during the wait stops this job. Sidekiq puts it
# in the queue again after a clean SIGTERM, and the next attempt completes it.
class ContentfulAssetJob < ApplicationJob
  # ⚠️ The code writes the status here, and not in a rescue in #perform. A mark of "failed" at the
  # first exception would change the record from failed to processing to failed at each attempt.
  # Thus "failed" here means that Sidekiq stopped after the last attempt.
  sidekiq_retries_exhausted do |msg, exception|
    id = msg["args"].first
    UploadLibrary.new.update(id, "status" => "failed", "error" => exception&.message.to_s.truncate(500))
    Rails.logger.error("Media: giving up on upload #{id} (#{exception&.class}: #{exception&.message})")
  end

  # @param id [String] The UploadLibrary record id, which is also the StagedUpload id.
  def perform(id)
    library = UploadLibrary.new
    record = library.find(id)
    return Rails.logger.info("Media: upload #{id} is gone; nothing to publish") if record.nil?
    return if record["status"] == "published"

    staged = StagedUpload.new.fetch(id)
    # ⚠️ PermanentError and not a plain raise: the Upload of Contentful is gone with this record,
    # thus no later attempt can find the bytes. A retry for 24 hours would only repeat the failure.
    raise PermanentError, "The picked file expired before it could be published." if staged.nil?

    contentful = ContentfulManagement.new
    asset_id = record["asset_id"]

    if asset_id.blank?
      created = contentful.create_asset(
        title: record["title"],
        description: record["alt"],
        file_name: staged[:file_name],
        content_type: staged[:content_type],
        upload_id: staged[:upload_id]
      )
      asset_id = created[:id]
      # ⚠️ The record keeps the asset id BEFORE the next call. A process or a publish that fails
      # makes this job run again, and a second `create_asset` would leave a duplicate asset in the
      # space, unpublished, with no message.
      library.update(id, "asset_id" => asset_id)
    end

    # This is safe to run again: it asks for a processing only when the file has no URL yet.
    version = contentful.ensure_processed(asset_id)
    contentful.publish_asset(asset_id, version)

    library.update(id, "status" => "published", "error" => nil, "published_at" => Time.now.utc.iso8601)
    StagedUpload.new.discard([ id ])

    Rails.logger.info("Media: published Contentful asset #{asset_id}")
  end
end
