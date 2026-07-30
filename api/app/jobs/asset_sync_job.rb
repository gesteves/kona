# Mirrors one Contentful image asset into R2, off the Contentful webhook request path.
# Takes a plain-string argument (JSON-serializable, per Sidekiq best practices) and is
# idempotent — AssetMirror skips an asset whose object is already in the bucket — so the
# inherited time-boxed retry (retry_for: 24.hours) is safe.
#
# Unlike most of this app's background work, a failure here raises rather than degrading: an
# unmirrored asset surfaces later as a broken image on a live page, so it has to retry. After
# the retries are exhausted the job lands in the Dead set (visible in the web UI); the
# assets:backfill task remains the broader reconciliation path, since Contentful does not
# retry webhook deliveries.
class AssetSyncJob < ApplicationJob
  # @param asset_id [String] The Contentful asset's sys.id.
  def perform(asset_id)
    AssetMirror.new.sync(asset_id)
  end
end
