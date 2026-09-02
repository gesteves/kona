require "vips"
require "blurhash"
require "base64"
require "erb"
require "open-uri"

# Makes the blurhash placeholder of a Contentful image asset, and keeps it in Redis. The card view
# reads one key and writes it into a `--placeholder` custom property.
#
# ⚠️ The request path never encodes an image. AssetBlurhashJob does the work one time for each
# asset, off the asset-publish webhook, and `rake blurhash:backfill` does it for the assets that
# exist.
#
# ⚠️ This is a copy of the four blurhash methods in web/lib/helpers/image_helpers.rb, and it must
# give the same result. A card of this app and a card of the build go on the same page.
class BlurhashPlaceholder < ApplicationService
  include ContentfulConsumer

  ASSET_QUERY = <<~GRAPHQL.freeze
    query($id: String!) {
      assets: assetCollection(where: { sys: { id: $id } }, limit: 1) {
        items {
          url
          width
          height
          contentType
          sys { publishedVersion }
        }
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

  # ⚠️ Only images.ctfassets.net has the Images API. downloads.ctfassets.net serves the file with
  # no transformation, and some image assets are there. Those assets get no placeholder, and the
  # card then shows the flat colour.
  IMAGES_API_HOST = "images.ctfassets.net".freeze

  # The width of the thumbnail that the blurhash comes from. The blurhash itself holds only a few
  # components, thus a larger thumbnail gives no better result.
  THUMBNAIL_WIDTH = 32

  # The key holds the published version of the asset, thus each entry is immutable and a new
  # publish makes a new key. The TTL removes the old entries, and it is not for freshness.
  CACHE_TTL = 90 * 24 * 60 * 60

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  # Reads the placeholder of an asset. This is the request path, thus it is one Redis GET.
  # @param asset_id [String, nil] The sys.id of the asset.
  # @param published_version [Integer, String, nil] The sys.publishedVersion of the asset.
  # @return [String, nil] The data URI, or nil when there is no entry.
  def read(asset_id, published_version)
    return if asset_id.blank? || published_version.blank?

    $redis.get(cache_key(asset_id, published_version))
  rescue StandardError => e
    # A card with no placeholder is correct. A card that raises is a 500 and an empty skeleton.
    Rails.logger.warn("blurhash: read failed for #{asset_id} (#{e.message})")
    nil
  end

  # Makes the placeholder of one asset and puts it in Redis. It does no work when the entry is
  # already there.
  #
  # ⚠️ It gets the thumbnail from the Contentful Images API, and not through the R2 mirror. A
  # mirror fetch would make this job wait for AssetSyncJob first. Each fetch is about 2 kB.
  # @param asset_id [String] The sys.id of the asset.
  # @return [Symbol] :stored, :present, or :skipped.
  #
  # ⚠️ It fails soft: a placeholder is an improvement, and a failure here must not put the job into
  # the retry set for a day. `rake blurhash:backfill` is the reconciliation path.
  def generate(asset_id)
    return log_skip(asset_id, "no asset id") if asset_id.blank?

    generate!(asset_id)
  rescue StandardError => e
    report_upstream_error(e, context: "blurhash placeholder #{asset_id}")
    log_skip(asset_id, "#{e.class}: #{e.message}")
  end

  # @see #generate
  def generate!(asset_id)
    asset = fetch_asset(asset_id)
    return log_skip(asset_id, "no published asset in Contentful") if asset.blank?
    return log_skip(asset_id, "not an image with dimensions") unless dimensions?(asset)
    return log_skip(asset_id, "a GIF has no placeholder") if asset[:contentType] == "image/gif"

    version = asset.dig(:sys, :publishedVersion)
    return log_skip(asset_id, "no published version") if version.blank?

    key = cache_key(asset_id, version)
    return log("#{asset_id} already has a placeholder", :present) if $redis.exists?(key)

    data_uri = build(asset)
    return log_skip(asset_id, "the encode gave no result") if data_uri.blank?

    $redis.set(key, data_uri, ex: CACHE_TTL)
    log("#{asset_id} stored (#{data_uri.bytesize} bytes)", :stored)
  end

  # Adds one job for each published asset.
  # @param dry_run [Boolean] True to count the assets and add no job.
  # @return [Integer, Symbol] The number of assets, or :skipped when the asset fetch failed.
  def backfill(dry_run: false)
    log("backfill starting#{' (dry run)' if dry_run}")
    # This is strict, because an incomplete page would add too few jobs and leave gaps that nothing
    # else finds.
    items = contentful.paginate(ASSETS_LIST_QUERY, collection: :assets, strict: true)
    return log_skip("backfill", "asset fetch failed") if items.nil?

    ids = items.filter_map { |item| item.dig(:sys, :id).presence }
    ids.each { |id| AssetBlurhashJob.perform_async(id) } unless dry_run
    log("backfill complete: #{ids.size} blurhash job(s) #{dry_run ? 'would be enqueued' : 'enqueued'}")
    ids.size
  end

  private

  # @param asset_id [String] The sys.id of the asset.
  # @param published_version [Integer, String] The sys.publishedVersion of the asset.
  # @return [String] The Redis key.
  def cache_key(asset_id, published_version)
    "blurhash:svg:#{asset_id}:#{published_version}"
  end

  # @param asset [Hash] The asset from Contentful.
  # @return [Boolean] True when the asset has a width and a height.
  def dimensions?(asset)
    asset[:width].to_i.positive? && asset[:height].to_i.positive?
  end

  # @param asset_id [String] The sys.id of the asset.
  # @return [Hash, nil] The asset fields, or nil.
  def fetch_asset(asset_id)
    contentful.items(ASSET_QUERY, { id: asset_id }, collection: :assets)&.first
  end

  # Encodes the thumbnail, decodes the blurhash, and wraps the result in the blur SVG.
  # @param asset [Hash] The asset from Contentful.
  # @return [String, nil] The data URI, or nil when a step fails.
  def build(asset)
    width = THUMBNAIL_WIDTH
    height = ((asset[:height].to_f / asset[:width].to_f) * width).round
    return if height < 1

    blurhash = encode(asset[:url], width, height)
    return unless blurhash && Blurhash.valid_blurhash?(blurhash)

    jpeg = decode_to_jpeg(blurhash, width, height)
    return if jpeg.blank?

    svg_data_uri(jpeg, asset[:width], asset[:height])
  end

  # Gets the thumbnail and encodes its blurhash.
  #
  # ⚠️ `fm=jpg` is necessary. With no format, Contentful returns the source format, and a libvips
  # with no loader for that format fails the decode into the rescue. There is then no placeholder
  # and no message.
  # @param url [String] The Contentful URL of the asset.
  # @param width [Integer] The width of the thumbnail.
  # @param height [Integer] The height of the thumbnail.
  # @return [String, nil] The blurhash, or nil on a failure.
  def encode(url, width, height)
    thumbnail_url = images_api_url(url, width, height)
    return if thumbnail_url.blank?

    data = URI.open(thumbnail_url, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT).read
    image = Vips::Image.new_from_buffer(data, "").colourspace(:srgb)
    image = image.flatten if image.has_alpha?
    Blurhash.encode(image.width, image.height, image.to_a.flatten)
  rescue StandardError => e
    Rails.logger.warn("blurhash: encode failed for #{url} (#{e.message})")
    nil
  end

  # @param url [String] The Contentful URL of the asset.
  # @param width [Integer] The width of the thumbnail.
  # @param height [Integer] The height of the thumbnail.
  # @return [String, nil] The Images API URL, or nil for an asset that is not on that host.
  def images_api_url(url, width, height)
    uri = URI.parse(url.to_s.start_with?("//") ? "https:#{url}" : url.to_s)
    return unless uri.host == IMAGES_API_HOST

    uri.query = URI.encode_www_form(w: width, h: height, fit: "fill", fm: "jpg")
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  # @param blurhash [String] The blurhash.
  # @param width [Integer] The width of the thumbnail.
  # @param height [Integer] The height of the thumbnail.
  # @return [String, nil] A JPEG data URI, or nil on a failure.
  def decode_to_jpeg(blurhash, width, height)
    # Blurhash.decode gives a nested [row][col][r,g,b,a] array, and Array#pack raises on it. Thus
    # the flatten is necessary. The decode gives opaque RGBA, thus the code removes the alpha band.
    pixels = Blurhash.decode(width, height, blurhash).flatten
    image = Vips::Image.new_from_memory(pixels.pack("C*"), width, height, 4, :uchar)
                       .copy(interpretation: :srgb)
                       .extract_band(0, n: 3)

    "data:image/jpeg;base64,#{Base64.strict_encode64(image.write_to_buffer('.jpg'))}"
  rescue StandardError => e
    Rails.logger.warn("blurhash: decode failed (#{e.message})")
    nil
  end

  # Wraps the JPEG in an SVG that blurs it to the shape of the asset.
  # @see https://css-tricks.com/the-blur-up-technique-for-loading-background-images/#recreating-the-blur-filter-with-svg
  # @param jpeg_data_uri [String] The JPEG data URI.
  # @param width [Integer] The width of the asset.
  # @param height [Integer] The height of the asset.
  # @return [String] The SVG data URI.
  def svg_data_uri(jpeg_data_uri, width, height)
    svg = <<~SVG
      <svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' viewBox='0 0 #{width} #{height}'>
        <filter id='blur' filterUnits='userSpaceOnUse' color-interpolation-filters='sRGB'>
          <feGaussianBlur stdDeviation='100' edgeMode='duplicate' />
          <feComponentTransfer>
            <feFuncA type='discrete' tableValues='1 1' />
          </feComponentTransfer>
        </filter>
        <image filter='url(#blur)' xlink:href='#{jpeg_data_uri}' x='0' y='0' height='100%' width='100%'/>
      </svg>
    SVG

    "data:image/svg+xml;charset=utf-8,#{ERB::Util.url_encode(svg.gsub(/\s+/, ' ').strip)}"
  end

  def log(message, result = nil)
    Rails.logger.info("blurhash: #{message}")
    result
  end

  def log_skip(subject, reason)
    log("#{subject} skipped (#{reason})", :skipped)
  end
end
