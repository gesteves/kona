require "aws-sdk-s3"
require "net/http"
require "tempfile"

# Mirrors Contentful's image assets into a Cloudflare R2 bucket, which the site serves images
# from instead of Contentful. Cloudflare Images fetches a transformation's source from whatever
# host the URL names, and a source outside the zone can't use Tiered Cache or Cache Reserve —
# so every PoP was pulling full-size originals from Contentful and re-pulling them on eviction.
#
# ⚠️ Cross-app contract: web's Contentful#rewrite_image_urls swaps only the host, keeping
# Contentful's path verbatim, and this writes objects under exactly that path. Neither side
# validates the other, and a mismatch 404s every image on the site with nothing reporting it.
# See the root CLAUDE.md.
#
# Driven by Contentful webhooks plus the `assets:backfill` rake task; no-ops without R2
# credentials.
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

  # ⚠️ Every ctfassets host, not just images.ctfassets.net: Contentful serves some image assets
  # from downloads.ctfassets.net, and mirroring only the images host would leave those hitting
  # Contentful forever. Paths are identical across hosts, so one key covers both.
  # web's Contentful#rewrite_image_urls must keep matching the same set.
  ASSET_HOST_SUFFIX = ".ctfassets.net".freeze

  # Contentful asset URLs are content-addressed — replacing a file mints a new token segment —
  # so an object's bytes never change and nothing ever needs invalidating.
  CACHE_CONTROL = "public, max-age=31536000, immutable".freeze

  # R2 ignores the region but the S3 client requires one.
  REGION = "auto".freeze

  # Contentful serves assets directly today; this is just so a redirect can't loop.
  MAX_REDIRECTS = 3

  # @return [Boolean] Whether the R2 credentials and bucket are configured.
  def configured?
    ENV["R2_ACCOUNT_ID"].present? && ENV["R2_ACCESS_KEY_ID"].present? &&
      ENV["R2_SECRET_ACCESS_KEY"].present? && bucket.present?
  end

  # Mirrors one asset into R2, skipping the work when the object is already there.
  #
  # ⚠️ Raises rather than degrading, unlike most services here: it runs in AssetSyncJob, where
  # the raise is what buys Sidekiq's retry, and a silently-skipped mirror surfaces later as a
  # broken image on a live page. Bugsnag's Sidekiq instrumentation reports it, so it isn't also
  # reported here.
  # @param asset_id [String] The Contentful asset's sys.id.
  # @return [Symbol] :mirrored, :present, or :skipped.
  def sync(asset_id)
    return log_skip(asset_id, "R2 is not configured") unless configured?

    asset = fetch_asset(asset_id)
    return log_skip(asset_id, "no published asset in Contentful") if asset.blank?

    key = object_key(asset[:url])
    return log_skip(asset_id, "not a ctfassets-hosted asset") if key.blank?
    return log("#{asset_id} already mirrored (#{key})", :present) if object_exists?(key)

    file = download(asset[:url])
    begin
      size = file.size
      client.put_object(
        bucket: bucket,
        key: key,
        body: file,
        # Without an explicit content type R2 serves application/octet-stream, which breaks
        # both the browser and Cloudflare Images.
        content_type: asset[:contentType].presence || "application/octet-stream",
        cache_control: CACHE_CONTROL
      )
    ensure
      file.close!
    end
    log("mirrored #{asset_id} → #{key} (#{size} bytes)", :mirrored)
  end

  # Enqueues a sync job for every published asset. Cheap to re-run, since each job skips assets
  # already in the bucket, so this doubles as the reconciliation net for webhook deliveries
  # Contentful never retries.
  # @param dry_run [Boolean] Report what would be enqueued without enqueuing it.
  # @return [Integer, Symbol] How many assets were found, or :skipped.
  def backfill(dry_run: false)
    return log_skip("backfill", "R2 is not configured") unless configured?

    log("backfill starting#{' (dry run)' if dry_run}")
    # Strict, because a partial page would under-enqueue and leave holes nothing else finds.
    items = contentful.paginate(ASSETS_LIST_QUERY, collection: :assets, strict: true)
    return log_skip("backfill", "asset fetch failed") if items.nil?

    ids = items.filter_map { |item| item.dig(:sys, :id).presence }
    ids.each { |id| AssetSyncJob.perform_async(id) } unless dry_run
    log("backfill complete: #{ids.size} asset sync job(s) #{dry_run ? 'would be enqueued' : 'enqueued'}")
    ids.size
  end

  # The R2 object key for an asset URL: its path verbatim, minus the leading slash. This is the
  # cross-app contract — web only swaps the host, so the path it emits must be what's used here.
  # @param url [String, nil] The asset URL, which Contentful returns protocol-relative.
  # @return [String, nil] The key, or nil for anything not hosted on ctfassets.
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

  # The S3 client for R2. Path-style addressing, since R2 has no virtual-host bucket
  # subdomains.
  def client
    @client ||= Aws::S3::Client.new(
      access_key_id: ENV["R2_ACCESS_KEY_ID"],
      secret_access_key: ENV["R2_SECRET_ACCESS_KEY"],
      endpoint: "https://#{ENV['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
      region: REGION,
      force_path_style: true
    )
  end

  # @return [Boolean] Whether the key is already in the bucket. This is what makes a re-run
  #   cost one HEAD per asset and no transfer.
  def object_exists?(key)
    client.head_object(bucket: bucket, key: key)
    true
  rescue Aws::S3::Errors::NotFound
    false
  end

  # Fetches the asset's URL and content type from Contentful. Re-fetched rather than read off
  # the webhook payload, which is a management-API shape and isn't trusted for content.
  # @return [Hash, nil]
  def fetch_asset(asset_id)
    return if asset_id.blank?

    contentful.items(ASSET_QUERY, { id: asset_id }, collection: :assets)&.first
  end

  # Downloads the asset to a rewound Tempfile, which the caller must close!.
  #
  # ⚠️ Net::HTTP#read_body, not HTTParty — don't "fix" this to match the house style. These
  # originals reach 38MB and the worker is a 512MB VM at concurrency 5, so buffering whole files
  # OOM-killed it mid-backfill; a hard kill isn't a failure Sidekiq can retry, so those jobs
  # vanished silently and only surfaced as 404s on live pages. HTTParty doesn't solve it even
  # with stream_body: measured at +52.3MB peak RSS against +1.2MB for the loop below. The
  # Tempfile then lets the S3 client upload from disk rather than a second copy in memory.
  # @raise [ApplicationService::HttpError] on a non-success response, so the job retries.
  def download(url, redirects_left: MAX_REDIRECTS)
    source = url.to_s.start_with?("//") ? "https:#{url}" : url.to_s
    uri = URI.parse(source)
    file = nil

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(Net::HTTP::Get.new(uri)) do |response|
        if response.is_a?(Net::HTTPRedirection) && redirects_left.positive? && response["location"].present?
          return download(response["location"], redirects_left: redirects_left - 1)
        end
        raise ApplicationService::HttpError.new(response.code.to_i, "", source) unless response.is_a?(Net::HTTPSuccess)

        # Created only once the status is known, so an error body is never written to disk.
        file = Tempfile.new("asset-mirror", binmode: true)
        begin
          response.read_body { |chunk| file.write(chunk) }
        rescue StandardError
          file.close!
          raise
        end
      end
    end

    file.rewind
    file
  end

  def log(message, result = nil)
    Rails.logger.info("asset mirror: #{message}")
    result
  end

  def log_skip(subject, reason)
    log("#{subject} skipped (#{reason})", :skipped)
  end
end
