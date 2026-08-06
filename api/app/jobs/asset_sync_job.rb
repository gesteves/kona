# Mirrors one Contentful image asset into R2, off the webhook request path. Idempotent —
# AssetMirror skips an asset already in the bucket — so the inherited 24-hour retry is safe.
#
# Unlike most of this app's background work, a failure raises rather than degrading: an
# unmirrored asset surfaces later as a broken image on a live page. Exhausted retries land in
# the Dead set; assets:backfill is the broader reconciliation path, since Contentful doesn't
# retry deliveries.
class AssetSyncJob < ApplicationJob
  # @param asset_id [String] The Contentful asset's sys.id.
  def perform(asset_id)
    AssetMirror.new.sync(asset_id)
  end
end
