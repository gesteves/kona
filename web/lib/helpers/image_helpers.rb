require "vips"
require "open-uri"
require "base64"
require "blurhash"
require "erb"

module ImageHelpers
  # Raised when IMAGES_URL is unset. Deliberately fatal rather than falling back to Contentful
  # resizing, which rendered fine while draining Contentful's asset bandwidth.
  class ImagesUrlMissing < StandardError
    MESSAGE = <<~MSG.freeze
      IMAGES_URL is unset, so there's no host to build a Cloudflare Images URL from.

      It's the host Cloudflare serves transformations from (<host>/cdn-cgi/image/…), i.e. the
      site's own public host. Set it in .env locally and in the build env for deploys.
    MSG

    def initialize(message = MESSAGE) = super
  end

  # Cloudflare Images transformation path. Options go in the path, not the query string.
  # @see https://developers.cloudflare.com/images/transform-images/transform-via-url/
  CDN_IMAGE_PATH = "/cdn-cgi/image/"

  # Maps Contentful's format names to Cloudflare's (note `jpeg`, not `jpg`). `auto` lets
  # Cloudflare pick avif/webp/jpeg from the Accept header, which is why no <picture> is needed.
  CDN_IMAGE_FORMATS = { "avif" => "avif", "webp" => "webp", "jpg" => "jpeg", "auto" => "auto" }.freeze

  # How long a rendered blurhash placeholder stays cached. Keyed by the asset's published_version,
  # so entries are immutable and a republish simply mints a new one — the TTL exists to reclaim
  # the superseded ones, not for freshness.
  BLURHASH_CACHE_TTL = 90 * 24 * 60 * 60

  # Timeouts for the thumbnail fetch each blurhash is encoded from.
  BLURHASH_OPEN_TIMEOUT = 5
  BLURHASH_READ_TIMEOUT = 15

  # Extracts the Contentful asset ID from an asset URL.
  # @param url [String, nil] An asset URL.
  # @return [String, nil] The asset ID, or nil for a blank URL.
  def get_asset_id(url)
    return if url.blank?
    url.split("/")[4]
  end

  # Assets keyed by sys.id, built once per build.
  # @return [Hash] Asset IDs mapped to asset objects.
  def asset_index
    memoize_by_collection(:asset_index, data.assets) do
      data.assets.each_with_object({}) { |a, h| h[a.sys.id] = a }
    end
  end

  # @param asset_id [String] The asset's ID.
  # @return [Array<Integer, Integer>] The asset's width and height, or nils when unknown.
  def get_asset_dimensions(asset_id)
    asset = asset_index[asset_id]
    return asset&.width, asset&.height
  end

  # @param asset_id [String] The asset's ID.
  # @return [String, nil] The asset's description (its alt text), or nil when it has none.
  def get_asset_description(asset_id)
    asset = asset_index[asset_id]
    asset&.description&.strip
  end

  # @param asset_id [String] The asset's ID.
  # @return [String, nil] The asset's content type, or nil when it isn't found.
  def get_asset_content_type(asset_id)
    asset = asset_index[asset_id]
    asset&.content_type
  end

  # @param asset_id [String] The asset's ID.
  # @return [String, nil] The asset's URL, or nil when it isn't found.
  def get_asset_url(asset_id)
    asset = asset_index[asset_id]
    asset&.url
  end

  # @param asset_id [String] The asset's ID.
  # @return [Integer, nil] The asset's published version, or nil when it isn't found.
  def get_asset_published_version(asset_id)
    asset = asset_index[asset_id]
    asset&.sys&.published_version
  end

  # Builds a Cloudflare Images transformation URL, hosted on IMAGES_URL.
  # @see https://developers.cloudflare.com/images/transform-images/transform-via-url/
  # @param original_url [String, nil] The image's source URL.
  # @param params [Hash] Transformation parameters (:w, :h, :fm, :fit).
  # @return [String, nil] The transformation URL, or nil for a blank URL so callers don't crash
  #   the build.
  # @raise [ImagesUrlMissing] if IMAGES_URL is unset.
  def cdn_image_url(original_url, params = {})
    return if original_url.blank?
    # Already transformed. Must precede get_asset_id, which reads the id from a fixed path
    # position a transformed URL doesn't have.
    return original_url if original_url.include?(CDN_IMAGE_PATH)
    raise ImagesUrlMissing if ENV["IMAGES_URL"].blank?

    asset_id = get_asset_id(original_url)
    asset_url = get_asset_url(asset_id)
    original_url = asset_url if asset_url.present?

    original_url = "https:#{original_url}" if original_url.start_with?("//")
    "#{ENV['IMAGES_URL']}#{CDN_IMAGE_PATH}#{cdn_image_options(params)}/#{original_url}"
  end

  # Serializes transformation parameters into Cloudflare's comma-separated option string.
  # @param params [Hash] The transformation parameters (:w, :h, :fm, :fit).
  # @return [String] The options, in a fixed order.
  def cdn_image_options(params)
    options = []
    format = CDN_IMAGE_FORMATS[params[:fm].to_s]
    options << "format=#{format}" if format.present?
    options << "width=#{params[:w]}" if params[:w].present?
    options << "height=#{params[:h]}" if params[:h].present?
    options << "fit=#{params[:fit]}" if params[:fit].present?
    # Cloudflare rejects a URL with no options, so callers wanting the image as-is get
    # anim=true — Cloudflare's own default, which transforms nothing and preserves the source
    # format, transparency, and gif animation.
    return "anim=true" if options.empty?

    options.join(",")
  end

  # Builds a responsive srcset.
  # @param url [String] The image's URL.
  # @param widths [Array<Integer>] The widths to generate candidates for.
  # @param square [Boolean] Whether to crop each candidate square.
  # @param options [Hash] Additional transformation parameters.
  # @return [String] The srcset attribute value.
  def srcset(url:, widths:, square: false, options: {})
    srcset = widths.map do |w|
      query = options.merge({ w: w })
      query.merge!({ h: w, fit: "cover" }) if square
      cdn_image_url(url, query) + " #{w}w"
    end
    srcset.join(", ")
  end

  # Builds the Open Graph card URL for a cover image, at Facebook's recommended size.
  # Centre-cropped on purpose — Cloudflare's saliency crop is unpredictable on these photos.
  # @param original_url [String] The image's source URL.
  # @return [String] The transformation URL.
  def open_graph_image_url(original_url)
    params = { w: 1200, h: 630, fit: "cover" }
    cdn_image_url(original_url, params)
  end

  # Bump after changing the card design, logo, or font in web/src/og-render.ts: it's folded into
  # the `v` cache buster below, so bumping re-mints every card URL. Cards are otherwise immutable.
  #
  # ⚠️ Keep the `v<number>` shape. `v` is caller-supplied at the edge, so src/og.ts validates it
  # against /^v\d+(-\d+)?$/ before keying the cache — that check is what stops `?v=<random>` from
  # minting an unbounded number of full satori+resvg renders. A value outside that shape still
  # renders, but every card collapses onto one cache entry, silently.
  OG_TEMPLATE_VERSION = "v1"

  # Builds the URL of the on-demand Open Graph card for a page, rendered by this site's own
  # Worker (web/src/og.ts) from the page's og:title. The card hangs off the page's own path, so
  # there is no caller-supplied path to validate. The ".png" is load-bearing — it's what keeps
  # the route out of the zone's Cache Rule (`not path contains "."`).
  # @param path [String] The page's root-relative path (current_page.url).
  # @param version [Integer, String, nil] The entry's sys.published_version, so a republish mints
  #   a new URL. Nil for listing pages, which aren't Contentful entries.
  # @return [String] The card's URL.
  def generate_open_graph_image_url(path, version = nil)
    v = version.present? ? "#{OG_TEMPLATE_VERSION}-#{version}" : OG_TEMPLATE_VERSION
    query = URI.encode_www_form(v: v)
    "#{root_url.to_s.chomp('/')}#{path.to_s.chomp('/')}/og.png?#{query}"
  end

  # @param w [Integer] The desired width.
  # @return [String, nil] The site icon's transformation URL, or nil when the site has no logo.
  # @raise [ImagesUrlMissing] if IMAGES_URL is unset.
  def site_icon_url(w:)
    original_url = data.site.logo.url
    cdn_image_url(original_url, { w: w })
  rescue ImagesUrlMissing
    # A misconfigured build must fail; the rescue below only covers a site entry with no logo.
    raise
  rescue StandardError
    nil
  end

  # Builds a data URI wrapping the asset's blurhash SVG, for use as a CSS background.
  # @see https://css-tricks.com/the-blur-up-technique-for-loading-background-images/#recreating-the-blur-filter-with-svg
  # @param asset_id [String] The asset's ID.
  # @return [String, nil] The data URI, or nil when no blurhash could be generated.
  def blurhash_svg_data_uri(asset_id)
    svg = blurhash_svg(asset_id)
    return if svg.blank?

    encoded_svg = ERB::Util.url_encode(svg.gsub(/\s+/, " "))
    "data:image/svg+xml;charset=utf-8,#{encoded_svg}"
  end

  # Builds an SVG that blurs the asset's blurhash thumbnail up to the asset's aspect ratio.
  # @param asset_id [String] The asset's ID.
  # @return [String, nil] The SVG markup, or nil when no blurhash could be generated.
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

  # Decodes the asset's blurhash into a tiny JPEG data URI, cached in Redis by published
  # version since generating one is expensive.
  #
  # ⚠️ Memoized in-process on top of the Redis cache: this runs inside render_body, which every
  # listing page calls for every article, so the Redis GET below was a network round trip per
  # image per page. The value is immutable (the key carries published_version), so one lookup
  # per asset per build is enough.
  # @param asset_id [String] The asset's ID.
  # @param width [Integer] The JPEG's width in pixels.
  # @return [String, nil] The data URI, or nil for a GIF or when encoding fails.
  def blurhash_jpeg_data_uri(asset_id, width: 32)
    store = memoize_by_collection(:blurhash_jpegs, data.assets) { {} }
    key = [ asset_id, width ]
    return store[key] if store.key?(key)

    store[key] = build_blurhash_jpeg_data_uri(asset_id, width)
  end

  # @param asset_id [String] The asset's ID.
  # @param width [Integer] The JPEG's width in pixels.
  # @return [String, nil] The data URI, or nil for a GIF or when encoding fails.
  def build_blurhash_jpeg_data_uri(asset_id, width)
    content_type = get_asset_content_type(asset_id)
    return if content_type == "image/gif"

    original_width, original_height = get_asset_dimensions(asset_id)
    published_version = get_asset_published_version(asset_id)
    return unless original_width && original_height && published_version

    cache_key = "blurhash:jpeg:#{asset_id}:#{published_version}:#{width}"
    jpeg = redis.get(cache_key)
    return jpeg if jpeg.present?

    height = ((original_height.to_f / original_width.to_f) * width).round
    blurhash = encode_blurhash(asset_id, width, height)
    return unless Blurhash.valid_blurhash?(blurhash)

    # Blurhash.decode returns a nested [row][col][r,g,b,a] array that Array#pack raises on, so
    # the flatten is required. It decodes to opaque RGBA, so the alpha band is dropped.
    pixels = Blurhash.decode(width, height, blurhash).flatten
    image = Vips::Image.new_from_memory(pixels.pack("C*"), width, height, 4, :uchar)
                       .copy(interpretation: :srgb)
                       .extract_band(0, n: 3)

    jpeg = "data:image/jpeg;base64,#{Base64.strict_encode64(image.write_to_buffer('.jpg'))}"
    # The key carries the asset's published_version, so every republish mints a new one and the
    # old entry is unreachable forever. Without a TTL the build's Redis — a metered Upstash
    # instance — only ever grows.
    redis.set(cache_key, jpeg, ex: BLURHASH_CACHE_TTL)
    jpeg
  rescue StandardError => e
    warn "Blurhash JPEG generation failed for asset #{asset_id}: #{e.message}"
    nil
  end

  # Encodes an asset's blurhash from a thumbnail resized through Cloudflare Images, so the
  # source is the R2 mirror like every other image.
  # The explicit `fm: 'jpg'` matters: with no format Cloudflare returns the source format, and a
  # libvips without that loader fails the decode into the rescue, i.e. silently no placeholder.
  # @param asset_id [String] The asset's ID.
  # @param width [Integer] The thumbnail's width.
  # @param height [Integer] The thumbnail's height.
  # @return [String, nil] The blurhash, or nil when encoding fails.
  def encode_blurhash(asset_id, width, height)
    url = cdn_image_url(get_asset_url(asset_id), { w: width, h: height, fm: "jpg" })
    # Timeouts are mandatory here: this runs once per uncached asset during the build, and the
    # rescue below catches errors, not a hang — one stalled response would park the whole build.
    data = URI.open(url, open_timeout: BLURHASH_OPEN_TIMEOUT, read_timeout: BLURHASH_READ_TIMEOUT).read
    image = Vips::Image.new_from_buffer(data, "").colourspace(:srgb)
    image = image.flatten if image.has_alpha?
    Blurhash.encode(image.width, image.height, image.to_a.flatten)
  rescue StandardError => e
    warn "Blurhash encoding failed for asset #{asset_id}: #{e.message}"
    nil
  end
end
