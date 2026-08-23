require "vips"
require "open-uri"
require "base64"
require "blurhash"
require "erb"

module ImageHelpers
  # The app raises this when IMAGES_URL has no value. It stops the build, on purpose. The
  # alternative, a fallback to Contentful resizing, renders correctly but uses the Contentful
  # asset bandwidth.
  class ImagesUrlMissing < StandardError
    MESSAGE = <<~MSG.freeze
      IMAGES_URL is unset, so there's no host to build a Cloudflare Images URL from.

      It's the host Cloudflare serves transformations from (<host>/cdn-cgi/image/…), i.e. the
      site's own public host. Set it in .env locally and in the build env for deploys.
    MSG

    def initialize(message = MESSAGE) = super
  end

  # The Cloudflare Images transformation path. The options go in the path, not the query string.
  # @see https://developers.cloudflare.com/images/transform-images/transform-via-url/
  CDN_IMAGE_PATH = "/cdn-cgi/image/"

  # Changes the Contentful format names into the Cloudflare names. Note `jpeg`, not `jpg`.
  # `auto` lets Cloudflare select avif, webp, or jpeg from the Accept header. Thus a <picture>
  # element is not necessary.
  CDN_IMAGE_FORMATS = { "avif" => "avif", "webp" => "webp", "jpg" => "jpeg", "auto" => "auto" }.freeze

  # The shape of a cover image on a card: the height divided by the width, that is, 3:2. The
  # `aspect-ratio` of .entry__cover-image in _entry.scss must be the same value.
  CARD_RATIO = Rational(2, 3)

  # The time that the cache keeps a rendered blurhash placeholder. The key contains the
  # published_version of the asset, thus each entry is immutable and a new publish makes a new
  # entry. The TTL removes the old entries. It is not for freshness.
  BLURHASH_CACHE_TTL = 90 * 24 * 60 * 60

  # The timeouts for the thumbnail fetch that each blurhash comes from.
  BLURHASH_OPEN_TIMEOUT = 5
  BLURHASH_READ_TIMEOUT = 15

  # Gets the Contentful asset ID from an asset URL.
  # @param url [String, nil] An asset URL.
  # @return [String, nil] The asset ID, or nil for a blank URL.
  def get_asset_id(url)
    return if url.blank?
    url.split("/")[4]
  end

  # The assets by sys.id. The app makes this one time for each build.
  # @return [Hash] The asset IDs and their asset objects.
  def asset_index
    memoize_by_collection(:asset_index, data.assets) do
      data.assets.each_with_object({}) { |a, h| h[a.sys.id] = a }
    end
  end

  # @param asset_id [String] The ID of the asset.
  # @return [Array<Integer, Integer>] The width and the height of the asset, or nils if unknown.
  def get_asset_dimensions(asset_id)
    asset = asset_index[asset_id]
    return asset&.width, asset&.height
  end

  # @param asset_id [String] The ID of the asset.
  # @return [String, nil] The description of the asset (its alt text), or nil if it has none.
  def get_asset_description(asset_id)
    asset = asset_index[asset_id]
    asset&.description&.strip
  end

  # @param asset_id [String] The ID of the asset.
  # @return [String, nil] The content type of the asset, or nil if the app cannot find it.
  def get_asset_content_type(asset_id)
    asset = asset_index[asset_id]
    asset&.content_type
  end

  # @param asset_id [String] The ID of the asset.
  # @return [String, nil] The URL of the asset, or nil if the app cannot find it.
  def get_asset_url(asset_id)
    asset = asset_index[asset_id]
    asset&.url
  end

  # @param asset_id [String] The ID of the asset.
  # @return [Integer, nil] The published version of the asset, or nil if the app cannot find it.
  def get_asset_published_version(asset_id)
    asset = asset_index[asset_id]
    asset&.sys&.published_version
  end

  # Makes a Cloudflare Images transformation URL on IMAGES_URL.
  # @see https://developers.cloudflare.com/images/transform-images/transform-via-url/
  # @param original_url [String, nil] The source URL of the image.
  # @param params [Hash] The transformation parameters (:w, :h, :fm, :fit).
  # @return [String, nil] The transformation URL, or nil for a blank URL. Thus a caller does not
  #   stop the build.
  # @raise [ImagesUrlMissing] If IMAGES_URL has no value.
  def cdn_image_url(original_url, params = {})
    return if original_url.blank?
    # The URL already has a transformation. This must come before get_asset_id, which reads the
    # id at a fixed position in the path that such a URL does not have.
    return original_url if original_url.include?(CDN_IMAGE_PATH)
    raise ImagesUrlMissing if ENV["IMAGES_URL"].blank?

    asset_id = get_asset_id(original_url)
    asset_url = get_asset_url(asset_id)
    original_url = asset_url if asset_url.present?

    original_url = "https:#{original_url}" if original_url.start_with?("//")
    "#{ENV['IMAGES_URL']}#{CDN_IMAGE_PATH}#{cdn_image_options(params)}/#{original_url}"
  end

  # Changes the transformation parameters into the Cloudflare option string, with a comma
  # between the options.
  # @param params [Hash] The transformation parameters (:w, :h, :fm, :fit).
  # @return [String] The options, in a fixed order.
  def cdn_image_options(params)
    options = []
    format = CDN_IMAGE_FORMATS[params[:fm].to_s]
    options << "format=#{format}" if format.present?
    options << "width=#{params[:w]}" if params[:w].present?
    options << "height=#{params[:h]}" if params[:h].present?
    options << "fit=#{params[:fit]}" if params[:fit].present?
    # Cloudflare refuses a URL with no options. Thus a caller that wants the image with no change
    # gets anim=true. This is the Cloudflare default: it does no transformation and keeps the
    # source format, the transparency, and the gif animation.
    return "anim=true" if options.empty?

    options.join(",")
  end

  # Makes a responsive srcset.
  # @param url [String] The URL of the image.
  # @param widths [Array<Integer>] The widths to make candidates for.
  # @param ratio [Numeric, nil] The height of a candidate divided by its width. It cuts each
  #   candidate to that shape. Nil keeps the shape of the asset.
  # @param options [Hash] More transformation parameters.
  # @return [String] The srcset attribute value.
  def srcset(url:, widths:, ratio: nil, options: {})
    srcset = widths.map do |w|
      query = options.merge({ w: w })
      query.merge!({ h: candidate_height(w, ratio), fit: "cover" }) if ratio
      cdn_image_url(url, query) + " #{w}w"
    end
    srcset.join(", ")
  end

  # @param width [Integer] The width of the candidate.
  # @param ratio [Numeric] The height divided by the width.
  # @return [Integer] The height of the candidate.
  def candidate_height(width, ratio)
    (width * ratio).round
  end

  # Makes the <img> of the cover image of an entry, for a card.
  #
  # ⚠️ It gives the element `alt=""`. The caller must put it in a link with `aria-hidden="true"`
  # and `tabindex="-1"`. The headline below the image already links to the same page, thus without
  # that, each card gives two identical tab stops and two identical entries in the link list of a
  # screen reader.
  # @param entry [Object] The article or the page.
  # @param variant [Symbol] The name of the srcset variant in data/srcsets.yml.
  # @return [String] The <img> element, or an empty string when the entry has no cover image.
  def cover_image_tag(entry, variant: :card)
    cover = entry&.cover_image
    return "" if cover&.url.blank?

    asset_id = get_asset_id(cover.url)
    config = data.srcsets.public_send(variant)
    widths = card_widths(config.widths, cover.width)
    # The first width of a variant is its 1x size at the largest breakpoint. Each other candidate
    # is for a smaller viewport or a denser screen. Thus it is the correct src.
    width = [ config.widths.first, widths.max ].min
    height = candidate_height(width, CARD_RATIO)

    # A GIF gets no transformation and no srcset: a transformation makes one static frame from it.
    # responsivize_images and resize_images have the same rule.
    gif = get_asset_content_type(asset_id) == "image/gif"
    # ⚠️ The src must be one of the candidates below, word for word, and `fm` is part of that.
    # Cloudflare renders and bills one transformation for each different URL, thus a src that only
    # looks the same is a second render of each cover image that no browser uses.
    src_query = { fm: "auto", w: width, h: height, fit: "cover" }

    attributes = {
      src: gif ? cdn_image_url(cover.url) : cdn_image_url(cover.url, src_query),
      width: width,
      height: height,
      alt: "",
      # `loading="lazy"` is necessary: each sizes list starts with `auto`, and a browser ignores
      # that keyword on an image that it loads at once.
      loading: "lazy",
      decoding: "async",
      class: "entry__cover-image placeholder",
      "data-controller": "image-placeholder",
      "data-action": "load->image-placeholder#removePlaceholder error->image-placeholder#removePlaceholder"
    }

    placeholder = blurhash_svg_data_uri(asset_id)
    attributes[:style] = "--placeholder:url('#{placeholder}');" if placeholder.present?

    unless gif
      attributes[:sizes] = config.sizes.join(", ")
      attributes[:srcset] = srcset(url: cover.url, widths: widths, ratio: CARD_RATIO, options: { fm: "auto" })
    end

    tag(:img, attributes)
  end

  # The candidate widths of a card image. It removes each width above the width of the asset,
  # because Cloudflare does not make an image larger than its source.
  # @param widths [Array<Integer>] The widths of the variant.
  # @param asset_width [Integer, nil] The width of the asset.
  # @return [Array<Integer>] The widths, in order, with no duplicate.
  def card_widths(widths, asset_width)
    candidates = widths.dup
    if asset_width.present?
      candidates << asset_width if asset_width < candidates.max
      candidates = candidates.reject { |w| w > asset_width }
    end
    candidates.uniq.sort
  end

  # Makes the Open Graph card URL for a cover image, at the size that Facebook recommends. It
  # cuts the image at the center, on purpose, because the Cloudflare saliency crop gives
  # unpredictable results on these photos.
  # @param original_url [String] The source URL of the image.
  # @return [String] The transformation URL.
  def open_graph_image_url(original_url)
    params = { w: 1200, h: 630, fit: "cover" }
    cdn_image_url(original_url, params)
  end

  # Increase this after you change the card design, the logo, or the font in web/src/og-render.ts.
  # It goes into the `v` cache buster below, thus an increase makes a new URL for each card. In
  # all other conditions a card is immutable.
  #
  # ⚠️ Keep the `v<number>` shape. The caller supplies `v` at the edge, thus src/og.ts checks it
  # against /^v\d+(-\d+)?$/ before it makes the cache key. That check stops `?v=<random>` from
  # making an unlimited number of full satori and resvg renders. A value outside that shape still
  # renders, but each card then uses one cache entry, with no message.
  OG_TEMPLATE_VERSION = "v1"

  # Makes the URL of the on-demand Open Graph card for a page. The Worker of this site
  # (web/src/og.ts) renders the card from the og:title of the page. The card URL comes from the
  # path of the page, thus there is no path from a caller to check. The ".png" is important: it
  # keeps the route out of the zone Cache Rule (`not path contains "."`).
  # @param path [String] The root-relative path of the page (current_page.url).
  # @param version [Integer, String, nil] The sys.published_version of the entry, thus a new
  #   publish makes a new URL. It is nil for a listing page, which is not a Contentful entry.
  # @return [String] The URL of the card.
  def generate_open_graph_image_url(path, version = nil)
    v = version.present? ? "#{OG_TEMPLATE_VERSION}-#{version}" : OG_TEMPLATE_VERSION
    query = URI.encode_www_form(v: v)
    "#{root_url.to_s.chomp('/')}#{path.to_s.chomp('/')}/og.png?#{query}"
  end

  # @param w [Integer] The necessary width.
  # @return [String, nil] The transformation URL of the site icon, or nil if the site has no logo.
  # @raise [ImagesUrlMissing] If IMAGES_URL has no value.
  def site_icon_url(w:)
    original_url = data.site.logo.url
    cdn_image_url(original_url, { w: w })
  rescue ImagesUrlMissing
    # A build with an incorrect configuration must fail. The rescue below is only for a site
    # entry with no logo.
    raise
  rescue StandardError
    nil
  end

  # Makes a data URI that contains the blurhash SVG of the asset, for a CSS background.
  # @see https://css-tricks.com/the-blur-up-technique-for-loading-background-images/#recreating-the-blur-filter-with-svg
  # @param asset_id [String] The ID of the asset.
  # @return [String, nil] The data URI, or nil if the app cannot make a blurhash.
  def blurhash_svg_data_uri(asset_id)
    svg = blurhash_svg(asset_id)
    return if svg.blank?

    encoded_svg = ERB::Util.url_encode(svg.gsub(/\s+/, " "))
    "data:image/svg+xml;charset=utf-8,#{encoded_svg}"
  end

  # Makes an SVG that blurs the blurhash thumbnail of the asset to the aspect ratio of the asset.
  # @param asset_id [String] The ID of the asset.
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

  # Decodes the blurhash of the asset into a small JPEG data URI. Redis caches it by published
  # version, because it is slow to make one.
  #
  # ⚠️ The app also keeps the value in the process, above the Redis cache. This runs in
  # render_body, which each listing page calls for each article. Thus the Redis GET below was one
  # network request for each image on each page. The value is immutable, because the key contains
  # the published_version. Thus one lookup for each asset for each build is sufficient.
  # @param asset_id [String] The ID of the asset.
  # @param width [Integer] The width of the JPEG in pixels.
  # @return [String, nil] The data URI, or nil for a GIF or if the encode fails.
  def blurhash_jpeg_data_uri(asset_id, width: 32)
    store = memoize_by_collection(:blurhash_jpegs, data.assets) { {} }
    key = [ asset_id, width ]
    return store[key] if store.key?(key)

    store[key] = build_blurhash_jpeg_data_uri(asset_id, width)
  end

  # @param asset_id [String] The ID of the asset.
  # @param width [Integer] The width of the JPEG in pixels.
  # @return [String, nil] The data URI, or nil for a GIF or if the encode fails.
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

    # Blurhash.decode returns a nested [row][col][r,g,b,a] array, and Array#pack raises on it.
    # Thus the flatten is necessary. The decode gives opaque RGBA, thus the code removes the
    # alpha band.
    pixels = Blurhash.decode(width, height, blurhash).flatten
    image = Vips::Image.new_from_memory(pixels.pack("C*"), width, height, 4, :uchar)
                       .copy(interpretation: :srgb)
                       .extract_band(0, n: 3)

    jpeg = "data:image/jpeg;base64,#{Base64.strict_encode64(image.write_to_buffer('.jpg'))}"
    # The key contains the published_version of the asset. Thus each new publish makes a new key
    # and nothing can read the old entry again. With no TTL, the Redis of the build, a metered
    # Upstash instance, becomes larger for all time.
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
  # placeholder and no message.
  # @param asset_id [String] The ID of the asset.
  # @param width [Integer] The width of the thumbnail.
  # @param height [Integer] The height of the thumbnail.
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
