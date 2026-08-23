# Makes the blurhash placeholder of one Contentful image asset, outside the webhook request. You
# can do it more than one time, because BlurhashPlaceholder does no work for an asset that already
# has an entry.
#
# ⚠️ This is separate from AssetSyncJob, on purpose. A placeholder is decoration and the R2 mirror
# is load-bearing. A failure here must never stop the mirror.
class AssetBlurhashJob < ApplicationJob
  # @param asset_id [String] The sys.id of the Contentful asset.
  def perform(asset_id)
    BlurhashPlaceholder.new.generate(asset_id)
  end
end
