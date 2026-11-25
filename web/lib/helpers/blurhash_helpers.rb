require "vips"
require "open-uri"
require "base64"
require "blurhash"

# The blurhash placeholder of an image: a small JPEG that the build decodes from the blurhash
# of the asset, in an SVG that blurs it. Redis keeps each one between two builds.
module BlurhashHelpers
  # The time that the cache keeps a rendered blurhash placeholder. The key contains the
  # published_version of the asset, thus each entry is immutable and a new publish makes a new
  # entry. The TTL removes the old entries. It is not for freshness.
  BLURHASH_CACHE_TTL = 90 * 24 * 60 * 60

  # The timeouts for the thumbnail fetch that each blurhash comes from.
  BLURHASH_OPEN_TIMEOUT = 5

  BLURHASH_READ_TIMEOUT = 15

  # Makes a data URI that contains the blurhash SVG of the asset, for a CSS background.
  # @see https://css-tricks.com/the-blur-up-technique-for-loading-background-images/#recreating-the-blur-filter-with-svg
  # @return [String, nil] The data URI, or nil if the app cannot make a blurhash.
  def blurhash_svg_data_uri(asset_id)
    svg = blurhash_svg(asset_id)
    return if svg.blank?

    "data:image/svg+xml;charset=utf-8,#{escape_svg_for_url(svg.gsub(/\s+/, " "))}"
  end

  # Decodes the blurhash of the asset into a small JPEG data URI. Redis caches it by published
  # version, because it is slow to make one. The app also keeps the value in the process, because
  # a Redis GET is one network request for each image on each page.
  #
  # ⚠️ `middleman build` renders in forked workers, and each fork has its own copy of that store.
  # Thus `before_build` in config.rb reads each placeholder from Redis one time, in the parent,
  # into `BlurhashHelpers.warm_blurhashes`. Without it, each worker asks Redis for each asset again.
  # @param width [Integer] The width of the JPEG in pixels.
  # @return [String, nil] The data URI, or nil for a GIF or if the encode fails.
  def blurhash_jpeg_data_uri(asset_id, width: 32)
    key = [ asset_id, width ]
    memoize_entry(:blurhash_jpegs, key, data.assets) do
      BlurhashHelpers.warm_blurhashes[key] || compute_blurhash_jpeg_data_uri(asset_id, width)
    end
  end

  class << self
    # @return [Hash{Array => String}] The placeholders that `before_build` read, by [asset id,
    #   width].
    def warm_blurhashes
      @warm_blurhashes ||= {}
    end

    # Reads the placeholder of each asset from Redis in one call, before the build forks. A miss
    # stays absent, and the worker that renders it makes it.
    # @param assets [Array<Object>] `data.assets`.
    # @return [Integer] The number of placeholders found.
    def warm_blurhashes!(assets, redis, width: 32)
      entries = Array(assets).filter_map do |asset|
        id = asset.sys&.id
        version = asset.sys&.published_version
        next if id.blank? || version.blank?

        [ [ id, width ], "blurhash:jpeg:#{id}:#{version}:#{width}" ]
      end
      return 0 if entries.empty?

      values = redis.mget(*entries.map(&:last))
      entries.zip(values).each { |(key, _), value| warm_blurhashes[key] = value if value.present? }
      values.count(&:present?)
    end
  end

  private

  # Escapes the few characters that an SVG in a `url()` cannot hold. `url_encode` escapes `/` and
  # `+` as well, and those are legal there. A listing page holds one placeholder for each card,
  # thus each byte here is on the page many times.
  #
  # ⚠️ The two quote characters must stay in this set. `blurhash_svg` writes each attribute with
  # `'`, and the caller puts the result in `url('...')`. A raw `'` closes that CSS string, and the
  # browser then paints no placeholder and no fallback color. `minify_html` also removes some raw
  # quotes, thus the SVG is not valid XML. Both faults give no message.
  def escape_svg_for_url(svg)
    svg.gsub(/[#%"'<> ]/) { |char| format("%%%02X", char.ord) }
  end

  # Makes an SVG that blurs the blurhash thumbnail of the asset to the aspect ratio of the asset.
  # @return [String, nil] The SVG markup, or nil if the app cannot make a blurhash.
  def blurhash_svg(asset_id)
    jpeg_data_uri = blurhash_jpeg_data_uri(asset_id)
    return if jpeg_data_uri.blank?

    width, height = get_asset_dimensions(asset_id)

    "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' viewBox='0 0 #{width} #{height}'>
      <filter id='blur' filterUnits='userSpaceOnUse' color-interpolation-filters='sRGB'>
        <feGaussianBlur stdDeviation='100' edgeMode='duplicate' />
        <feComponentTransfer>
          <feFuncA type='discrete' tableValues='1 1' />
        </feComponentTransfer>
      </filter>
      <image filter='url(#blur)' xlink:href='#{jpeg_data_uri}' x='0' y='0' height='100%' width='100%'/>
    </svg>"
  end

  # Gets the placeholder from Redis, or makes it and puts it there.
  # @return [String, nil] The data URI, or nil for a GIF or if the encode fails.
  def compute_blurhash_jpeg_data_uri(asset_id, width)
    return if gif_asset?(asset_id)

    original_width, original_height = get_asset_dimensions(asset_id)
    published_version = get_asset_published_version(asset_id)
    return unless original_width && original_height && published_version

    cache_key = "blurhash:jpeg:#{asset_id}:#{published_version}:#{width}"
    jpeg = redis.get(cache_key)
    return jpeg if jpeg.present?

    height = ((original_height.to_f / original_width.to_f) * width).round
    blurhash = encode_blurhash(asset_id, width, height)
    return unless Blurhash.valid_blurhash?(blurhash)

    # Blurhash.decode returns a nested [row][col][r,g,b,a] array, and Array#pack raises on it.
    # Thus the flatten is necessary. The decode gives opaque RGBA, thus the code removes the
    # alpha band.
    pixels = Blurhash.decode(width, height, blurhash).flatten
    image = Vips::Image.new_from_memory(pixels.pack("C*"), width, height, 4, :uchar)
                       .copy(interpretation: :srgb)
                       .extract_band(0, n: 3)

    # `strip` removes the Exif block, which is a large part of such a small JPEG.
    jpeg = "data:image/jpeg;base64,#{Base64.strict_encode64(image.jpegsave_buffer(strip: true))}"
    # With no TTL, the metered Redis of the build becomes larger for all time. Refer to
    # BLURHASH_CACHE_TTL.
    redis.set(cache_key, jpeg, ex: BLURHASH_CACHE_TTL)
    jpeg
  rescue StandardError => e
    warn "Blurhash JPEG generation failed for asset #{asset_id}: #{e.message}"
    nil
  end

  # Makes the blurhash of an asset from a thumbnail that Cloudflare Images resizes. Thus the
  # source is the R2 mirror, as it is for each other image.
  # The `fm: 'jpg'` is important: with no format, Cloudflare returns the source format, and a
  # libvips with no loader for that format fails the decode into the rescue. There is then no
  # placeholder, and only a warning in the build log.
  # @return [String, nil] The blurhash, or nil if the encode fails.
  def encode_blurhash(asset_id, width, height)
    url = cdn_image_url(get_asset_url(asset_id), { w: width, h: height, fm: "jpg" })
    # The timeouts are necessary here. This runs one time for each asset that is not in the cache
    # during the build. The rescue below catches an error, but not a stop. One response that
    # stops would stop the full build.
    data = URI.open(url, open_timeout: BLURHASH_OPEN_TIMEOUT, read_timeout: BLURHASH_READ_TIMEOUT).read
    image = Vips::Image.new_from_buffer(data, "").colourspace(:srgb)
    image = image.flatten if image.has_alpha?
    Blurhash.encode(image.width, image.height, image.to_a.flatten)
  rescue StandardError => e
    warn "Blurhash encoding failed for asset #{asset_id}: #{e.message}"
    nil
  end
end
