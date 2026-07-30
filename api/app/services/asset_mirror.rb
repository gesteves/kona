require "aws-sdk-s3"

# Mirrors Contentful's image assets into a Cloudflare R2 bucket, which the web site serves
# its images from instead of Contentful.
#
# Why: every image on the site is a Cloudflare Images transformation, and Cloudflare fetches
# the untransformed *source* from whatever host the URL names. A source outside our zone can't
# use Tiered Cache or Cache Reserve, so every Cloudflare PoP independently pulled the full-size
# original from Contentful and re-pulled it on eviction — which is what drove Contentful's asset
# bandwidth up. Mirroring into R2 and pointing the source at a hostname in our own zone means
# production never reaches Contentful at all: only this mirror does, once per asset version.
#
# ⚠️ CROSS-APP CONTRACT. The web build rewrites asset URLs onto IMAGE_HOST keeping Contentful's
# path verbatim (web/lib/data/contentful.rb#rewrite_image_urls), and this writes objects under
# exactly that path. Neither side validates the other: a mismatched bucket, custom domain, or key
# shape produces a 404 on every image with nothing reporting it. See the root CLAUDE.md.
#
# Driven by Contentful webhooks (Webhooks::ContentfulController) plus the `assets:backfill` rake
# task, mirroring how StandardSite is driven. Everything no-ops when the R2 credentials are
# absent, so a credential-free environment simply doesn't mirror.
class AssetMirror < ApplicationService
  include ContentfulConsumer

  ASSET_QUERY = <<~GRAPHQL.freeze
    query($id: String!) {
      assets: assetCollection(where: { sys: { id: $id } }, limit: 1) {
        items { url contentType }
      }
    }
  GRAPHQL

  ASSETS_LIST_QUERY = <<~GRAPHQL.freeze
    query($skip: Int, $limit: Int) {
      assets: assetCollection(skip: $skip, limit: $limit) {
        items { sys { id } }
      }
    }
  GRAPHQL

  # ⚠️ Every ctfassets host, not just images.ctfassets.net. Contentful serves some image assets
  # from downloads.ctfassets.net (it's not an images-vs-files split — this space has 20 JPEGs
  # there), and mirroring only the images host would silently leave those hitting Contentful
  # forever. Asset paths are identical across the hosts, so one key covers an asset either way,
  # and the bytes are fetched from whichever host Contentful named.
  # web's Contentful#rewrite_image_urls must keep matching the same set.
  ASSET_HOST_SUFFIX = ".ctfassets.net".freeze

  # Contentful asset URLs are content-addressed: replacing an asset's file mints a new token
  # segment, so a key's bytes never change and nothing ever needs invalidating.
  CACHE_CONTROL = "public, max-age=31536000, immutable".freeze

  # R2 ignores the region but the S3 client requires one.
  REGION = "auto".freeze

  # @return [Boolean] Whether the R2 credentials and bucket are configured.
  def configured?
    ENV["R2_ACCOUNT_ID"].present? && ENV["R2_ACCESS_KEY_ID"].present? &&
      ENV["R2_SECRET_ACCESS_KEY"].present? && bucket.present?
  end

  # Mirrors one asset into R2, skipping the work when its object is already there.
  #
  # ⚠️ Raises on failure rather than degrading, unlike most services here: this runs in
  # AssetSyncJob, where a raise is what buys Sidekiq's retry, and a silently-skipped mirror
  # surfaces later as a broken image on a live page. Bugsnag's Sidekiq instrumentation reports
  # the raise, so it isn't also reported here (that would double-notify).
  #
  # @param asset_id [String] The Contentful asset's sys.id.
  # @return [Symbol] :mirrored, :present, or :skipped.
  def sync(asset_id)
    return log_skip(asset_id, "R2 is not configured") unless configured?

    asset = fetch_asset(asset_id)
    return log_skip(asset_id, "no published asset in Contentful") if asset.blank?

    key = object_key(asset[:url])
    return log_skip(asset_id, "not a ctfassets-hosted asset") if key.blank?
    return log("#{asset_id} already mirrored (#{key})", :present) if object_exists?(key)

    body = download(asset[:url])
    client.put_object(
      bucket: bucket,
      key: key,
      body: body,
      # ⚠️ Without an explicit content type R2 serves application/octet-stream, which breaks
      # both the browser and Cloudflare Images.
      content_type: asset[:contentType].presence || "application/octet-stream",
      cache_control: CACHE_CONTROL
    )
    log("mirrored #{asset_id} → #{key} (#{body.bytesize} bytes)", :mirrored)
  end

  # Enqueues a sync job for every published asset. Safe to re-run: each job skips assets already
  # in the bucket, so this doubles as the reconciliation net for webhook deliveries Contentful
  # never retries (the same role standard_site:backfill plays).
  #
  # @param dry_run [Boolean] Report what would be enqueued without enqueuing anything.
  # @return [Integer, Symbol] The number of assets found, or :skipped.
  def backfill(dry_run: false)
    return log_skip("backfill", "R2 is not configured") unless configured?

    log("backfill starting#{' (dry run)' if dry_run}")
    # strict: a partial page would silently under-enqueue and leave holes in the mirror that
    # nothing else would find.
    items = contentful.paginate(ASSETS_LIST_QUERY, collection: :assets, strict: true)
    return log_skip("backfill", "asset fetch failed") if items.nil?

    ids = items.filter_map { |item| item.dig(:sys, :id).presence }
    ids.each { |id| AssetSyncJob.perform_async(id) } unless dry_run
    log("backfill complete: #{ids.size} asset sync job(s) #{dry_run ? 'would be enqueued' : 'enqueued'}")
    ids.size
  end

  # The R2 object key for a Contentful asset URL: its path, verbatim, minus the leading slash
  # (`{space}/{asset id}/{token}/{filename}`). Returns nil for anything not hosted on ctfassets.
  #
  # ⚠️ This is the cross-app contract — web/lib/data/contentful.rb only swaps the host, so the
  # path it emits must be exactly what's used here.
  #
  # @param url [String, nil] The asset URL (Contentful returns these protocol-relative).
  # @return [String, nil]
  def object_key(url)
    return if url.blank?

    uri = URI.parse(url.to_s.start_with?("//") ? "https:#{url}" : url.to_s)
    return unless uri.host.to_s.end_with?(ASSET_HOST_SUFFIX)

    uri.path.delete_prefix("/").presence
  rescue URI::InvalidURIError
    nil
  end

  private

  def bucket
    ENV["R2_BUCKET"]
  end

  # R2's S3-compatible endpoint. Path-style addressing: R2 doesn't do virtual-host style
  # bucket subdomains.
  def client
    @client ||= Aws::S3::Client.new(
      access_key_id: ENV["R2_ACCESS_KEY_ID"],
      secret_access_key: ENV["R2_SECRET_ACCESS_KEY"],
      endpoint: "https://#{ENV['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
      region: REGION,
      force_path_style: true
    )
  end

  # @return [Boolean] Whether the key is already in the bucket. This is what makes retries and
  #   the backfill cheap — a re-run costs one HEAD per asset and no transfer.
  def object_exists?(key)
    client.head_object(bucket: bucket, key: key)
    true
  rescue Aws::S3::Errors::NotFound
    false
  end

  # Fetches the asset's URL and content type from Contentful. Deliberately re-fetched rather
  # than read off the webhook payload, matching StandardSite: the payload is a management-API
  # shape and is never trusted for content.
  # @return [Hash, nil]
  def fetch_asset(asset_id)
    return if asset_id.blank?

    contentful.items(ASSET_QUERY, { id: asset_id }, collection: :assets)&.first
  end

  # @raise [ApplicationService::HttpError] on a non-success response, so the job retries.
  def download(url)
    source = url.to_s.start_with?("//") ? "https:#{url}" : url.to_s
    response = HTTParty.get(source)
    raise ApplicationService::HttpError.new(response.code, response.body, source) unless response.success?

    response.body
  end

  def log(message, result = nil)
    Rails.logger.info("asset mirror: #{message}")
    result
  end

  def log_skip(subject, reason)
    log("#{subject} skipped (#{reason})", :skipped)
  end
end
