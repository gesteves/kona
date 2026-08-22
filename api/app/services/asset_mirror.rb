require "aws-sdk-s3"
require "net/http"
require "tempfile"

# Copies the Contentful image assets into a Cloudflare R2 bucket. The site then serves the images
# from that bucket, and not from Contentful. Cloudflare Images gets the source of a transformation
# from the host that the URL names, and a source outside the zone cannot use Tiered Cache or Cache
# Reserve. Thus each PoP got the full-size originals from Contentful, and got them again after an
# eviction.
#
# ⚠️ This is a contract between the two apps: the Contentful#rewrite_image_urls of web changes only
# the host and keeps the Contentful path, and this code writes each object at that same path.
# Neither side checks the other, and a difference makes each image on the site 404 and nothing
# reports it. Refer to the root CLAUDE.md.
#
# Contentful webhooks and the `assets:backfill` rake task start this. It does nothing without the
# R2 credentials.
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

  # ⚠️ Match each ctfassets host, not only images.ctfassets.net. Contentful serves some image
  # assets from downloads.ctfassets.net. If you copy only the images host, those assets go to
  # Contentful for all time. The paths are the same on both hosts, thus one key is sufficient for
  # both. The Contentful#rewrite_image_urls of web must match the same set.
  ASSET_HOST_SUFFIX = ".ctfassets.net".freeze

  # A Contentful asset URL contains the address of the content: a new file gives a new token
  # segment. Thus the bytes of an object never change and nothing needs an invalidation.
  CACHE_CONTROL = "public, max-age=31536000, immutable".freeze

  # R2 ignores the region, but the S3 client needs one.
  REGION = "auto".freeze

  # Contentful serves the assets directly today. This is only to stop a loop of redirects.
  MAX_REDIRECTS = 3

  # @return [Boolean] True if the R2 credentials and the bucket are available.
  def configured?
    ENV["R2_ACCOUNT_ID"].present? && ENV["R2_ACCESS_KEY_ID"].present? &&
      ENV["R2_SECRET_ACCESS_KEY"].present? && bucket.present?
  end

  # Copies one asset into R2. It does no work if the object is already there.
  #
  # ⚠️ This raises and does not give a smaller result, and most services here are different. It
  # runs in AssetSyncJob, where the raise is what makes Sidekiq do the job again. An asset that
  # this code does not copy, with no message, becomes a broken image on a live page later. The
  # Sidekiq instrumentation of Bugsnag reports it, thus this code does not also report it.
  # @param asset_id [String] The sys.id of the Contentful asset.
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
        # Without a content type, R2 serves application/octet-stream, and that stops both the
        # browser and Cloudflare Images.
        content_type: asset[:contentType].presence || "application/octet-stream",
        cache_control: CACHE_CONTROL
      )
    ensure
      file.close!
    end
    log("mirrored #{asset_id} → #{key} (#{size} bytes)", :mirrored)
  end

  # Adds a sync job to the queue for each published asset. It is fast to run again, because each
  # job does no work for an asset that is already in the bucket. Thus this is also the
  # reconciliation net for the webhook deliveries that Contentful does not send again.
  # @param dry_run [Boolean] True to report the jobs but not add them to the queue.
  # @return [Integer, Symbol] The number of assets, or :skipped.
  def backfill(dry_run: false)
    return log_skip("backfill", "R2 is not configured") unless configured?

    log("backfill starting#{' (dry run)' if dry_run}")
    # This is strict, because an incomplete page would add too few jobs and leave gaps that
    # nothing else finds.
    items = contentful.paginate(ASSETS_LIST_QUERY, collection: :assets, strict: true)
    return log_skip("backfill", "asset fetch failed") if items.nil?

    ids = items.filter_map { |item| item.dig(:sys, :id).presence }
    ids.each { |id| AssetSyncJob.perform_async(id) } unless dry_run
    log("backfill complete: #{ids.size} asset sync job(s) #{dry_run ? 'would be enqueued' : 'enqueued'}")
    ids.size
  end

  # The R2 object key for an asset URL: its path, with no slash at the start. This is the contract
  # between the two apps: web changes only the host, thus the path that web writes must be the
  # path that this code uses.
  # @param url [String, nil] The asset URL. Contentful returns it with no protocol.
  # @return [String, nil] The key, or nil for a URL that is not on ctfassets.
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

  # The S3 client for R2. It puts the bucket in the path, because R2 has no bucket subdomain on
  # the host.
  def client
    @client ||= Aws::S3::Client.new(
      access_key_id: ENV["R2_ACCESS_KEY_ID"],
      secret_access_key: ENV["R2_SECRET_ACCESS_KEY"],
      endpoint: "https://#{ENV['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
      region: REGION,
      force_path_style: true
    )
  end

  # @return [Boolean] True if the key is already in the bucket. This is what makes a second run
  #   cost one HEAD for each asset and no data transfer.
  def object_exists?(key)
    client.head_object(bucket: bucket, key: key)
    true
  rescue Aws::S3::Errors::NotFound
    false
  end

  # Gets the URL and the content type of the asset from Contentful. This code does not read the
  # webhook payload, which has the management-API shape and is not a source of content.
  # @return [Hash, nil]
  def fetch_asset(asset_id)
    return if asset_id.blank?

    contentful.items(ASSET_QUERY, { id: asset_id }, collection: :assets)&.first
  end

  # Downloads the asset into a Tempfile at position 0. The caller must call close! on it.
  #
  # ⚠️ This uses Net::HTTP#read_body, not HTTParty. Do not change it to the usual style. These
  # originals are as large as 38MB, and the worker is a 512MB VM at concurrency 5. Thus a buffer
  # of the full file caused an OOM kill during a backfill. A hard kill is not a failure that
  # Sidekiq can do again, thus those jobs went away with no message and showed only as 404s on
  # live pages. HTTParty does not correct this, even with stream_body: a measurement gave +52.3MB
  # peak RSS against +1.2MB for the loop below. The Tempfile then lets the S3 client upload from
  # the disk, and not from a second copy in memory.
  # @raise [ApplicationService::HttpError] If the response is not a success, thus the job runs
  #   again.
  # @raise [ArgumentError] If a redirect goes away from ctfassets. Refer to #fetch_uri.
  def download(url, redirects_left: MAX_REDIRECTS, base: nil)
    uri = fetch_uri(url, base: base)
    source = uri.to_s
    file = nil

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(Net::HTTP::Get.new(uri)) do |response|
        if response.is_a?(Net::HTTPRedirection) && redirects_left.positive? && response["location"].present?
          # ⚠️ The code resolves this and checks it against the same list. It does not use it as
          # it is. The code writes the result to R2 at the ORIGINAL key from ctfassets, and the
          # public image host serves it. Thus a redirect with no check would publish the target
          # of that redirect, and that can be something that only this VM can reach.
          return download(response["location"], redirects_left: redirects_left - 1, base: uri)
        end
        raise ApplicationService::HttpError.new(response.code.to_i, "", source) unless response.is_a?(Net::HTTPSuccess)

        # The code makes this only after it knows the status, thus it never writes an error body
        # to the disk.
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

  # Resolves one redirect of #download and makes sure that it is still an HTTPS fetch from
  # ctfassets.
  #
  # ⚠️ This raises and does not return nil, on purpose. The rule for AssetSyncJob is that an asset
  # that the code does not copy becomes a broken image on a live page later. Thus a redirect that
  # fails this check must stop the job with a message, and not copy nothing.
  #
  # @param url [String] The asset URL, or the Location of a redirect, which can be relative.
  # @param base [URI, nil] The URI that the redirect came from, to resolve a relative Location.
  # @return [URI::HTTPS]
  # @raise [ArgumentError] If the target is not HTTPS on a ctfassets host.
  def fetch_uri(url, base: nil)
    normalized = url.to_s.start_with?("//") ? "https:#{url}" : url.to_s
    uri = base ? URI.join(base, normalized) : URI.parse(normalized)

    unless uri.scheme == "https" && uri.host.to_s.end_with?(ASSET_HOST_SUFFIX)
      raise ArgumentError, "Refusing to mirror from #{uri.scheme}://#{uri.host}"
    end

    uri
  rescue URI::InvalidURIError, URI::BadURIError => e
    raise ArgumentError, "Refusing to mirror from an unparseable URL (#{e.message})"
  end

  def log(message, result = nil)
    Rails.logger.info("asset mirror: #{message}")
    result
  end

  def log_skip(subject, reason)
    log("#{subject} skipped (#{reason})", :skipped)
  end
end
