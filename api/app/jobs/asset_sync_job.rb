# Copies one Contentful image asset into R2, outside the webhook request. You can do it more than
# one time, because AssetMirror does no work for an asset that is already in the bucket. Thus the
# 24-hour retry from the parent class is safe.
#
# Most of the background work of this app is different: a failure here raises and does not give a
# smaller result, because an asset that the code does not copy becomes a broken image on a live page
# later. After the last attempt the job goes into the Dead set. assets:backfill is the larger
# reconciliation path, because Contentful does not send a delivery again.
class AssetSyncJob < ApplicationJob
  # @param asset_id [String] The sys.id of the Contentful asset.
  def perform(asset_id)
    AssetMirror.new.sync(asset_id)
  end
end
