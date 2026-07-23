require 'vips'
require 'open-uri'
require 'base64'
require 'blurhash'
require 'erb'

module ImageHelpers
  # Raised when IMAGES_URL is unset. Every image on the site goes through Cloudflare, so there
  # is no sensible way to build one without knowing the host to hang the transformation off.
  class ImagesUrlMissing < StandardError
    MESSAGE = <<~MSG.freeze
      IMAGES_URL is unset, so there's no host to build a Cloudflare Images URL from.

      It's the host Cloudflare serves transformations from (<host>/cdn-cgi/image/…), i.e. the
      site's own public host. Set it in .env locally and in Netlify's env for deploys.

      This used to fall back to Contentful's resizing, which rendered fine while quietly
      draining Contentful's asset bandwidth — the exact thing Cloudflare Images replaced. It
      now fails instead, so a missing var can't ship unnoticed.
    MSG

    def initialize(message = MESSAGE) = super
  end

  # Cloudflare Images serves transformations from this path on our own zone. Options go in the
  # path, not the query string.
  # @see https://developers.cloudflare.com/images/transform-images/transform-via-url/
  CDN_IMAGE_PATH = '/cdn-cgi/image/'

  # Maps the format names our callers use (which are also Contentful's) to Cloudflare's. Note
  # `jpeg`, not `jpg`. `auto` lets Cloudflare pick avif/webp/jpeg from the request's Accept
  # header — which is why we don't need a <picture> element, and why one srcset candidate is
  # billed as a single transformation no matter how many formats it ends up serving.
  CDN_IMAGE_FORMATS = { 'avif' => 'avif', 'webp' => 'webp', 'jpg' => 'jpeg', 'auto' => 'auto' }.freeze

  # Extracts the asset ID from a URL.
  # @param url [String, nil] The URL from which to extract the asset ID.
  # @return [String, nil] The asset ID extracted from the URL, or nil for a blank URL.
  def get_asset_id(url)
    return if url.blank?
    url.split('/')[4]
  end

  # Returns a hash of assets keyed by sys.id for O(1) lookups, built once per build
  # (memoize_by_collection).
  # @return [Hash] A hash mapping asset IDs to asset objects.
  def asset_index
    memoize_by_collection(:asset_index, data.assets) do
      data.assets.each_with_object({}) { |a, h| h[a.sys.id] = a }
    end
  end

  # Retrieves the dimensions (width and height) of an asset by its ID.
  # @param asset_id [String] The ID of the asset for which to retrieve dimensions.
  # @return [Integer, Integer] The width and height of the asset, or nil if the asset is not found.
  def get_asset_dimensions(asset_id)
    asset = asset_index[asset_id]
    return asset&.width, asset&.height
  end

  # Retrieves the description (aka alt text) of an asset by its ID.
  # @param asset_id [String] The ID of the asset for which to retrieve the description.
  # @return [String, nil] The description of the asset, or nil if the asset is not found or has no description.
  def get_asset_description(asset_id)
    asset = asset_index[asset_id]
    asset&.description&.strip
  end

  # Retrieves the content type of an asset by its ID.
  # @param asset_id [String] The ID of the asset for which to retrieve the content type.
  # @return [String, nil] The content type of the asset, or nil if the asset is not found.
  def get_asset_content_type(asset_id)
    asset = asset_index[asset_id]
    asset&.content_type
  end

  # Retrieves the URL of an asset by its ID.
  # @param asset_id [String] The ID of the asset for which to retrieve the URL.
  # @return [String, nil] The URL of the asset, or nil if the asset is not found.
  def get_asset_url(asset_id)
    asset = asset_index[asset_id]
    asset&.url
  end

  # Retrieves the published version of an asset by its ID.
  # @param asset_id [String] The ID of the asset for which to retrieve the published version.
  # @return [Integer, nil] The published version of the asset, or nil if the asset is not found.
  def get_asset_published_version(asset_id)
    asset = asset_index[asset_id]
    asset&.sys&.published_version
  end

  # Generates a CDN image URL with optional transformation parameters.
  # Cloudflare serves transformations from a host it fronts, so this needs to know which one:
  # IMAGES_URL, required everywhere including locally. Set it and `middleman server` renders
  # exactly what production does — auto avif/webp, saliency-cropped Open Graph cards — with the
  # images fetched from the live zone. Unset, this raises rather than resizing via Contentful:
  # that fallback rendered a perfectly good-looking site while draining Contentful's bandwidth,
  # so its only real effect was to hide a broken deploy. See ImagesUrlMissing.
  # @see https://developers.cloudflare.com/images/transform-images/transform-via-url/
  # @param original_url [String, nil] The original URL of the image.
  # @param params [Hash] (Optional) Transformation parameters (:w, :h, :fm, :fit).
  # @return [String, nil] The CDN image URL, or nil for a blank URL (e.g. a site entry with
  #   no logo) so callers don't crash the build.
  # @raise [ImagesUrlMissing] if IMAGES_URL is unset.
  def cdn_image_url(original_url, params = {})
    return if original_url.blank?
    # Already transformed; don't wrap it again. This has to come before get_asset_id, which
    # reads the id from a fixed path position that a transformed URL doesn't have.
    return original_url if original_url.include?(CDN_IMAGE_PATH)
    raise ImagesUrlMissing if ENV['IMAGES_URL'].blank?

    asset_id = get_asset_id(original_url)
    asset_url = get_asset_url(asset_id)
    original_url = asset_url if asset_url.present?

    original_url = "https:#{original_url}" if original_url.start_with?('//')
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
    # Cloudflare rejects a URL with no options at all, so callers that want the image as-is
    # (the <img> fallback, animated gifs, the Open Graph logo) get anim=true — Cloudflare's
    # own default, so it transforms nothing. Emitting no format is the point: that's what
    # preserves the source format, its transparency, and a gif's animation.
    return 'anim=true' if options.empty?

    options.join(',')
  end

  # Generates a Contentful Images API URL. One caller: encode_blurhash, which uses it
  # deliberately, so that generating a placeholder never depends on our zone being up or on
  # Cloudflare's quota. Fidelity is lower than Cloudflare's (no auto format), which is fine for
  # a 32px thumbnail nobody sees. This is NOT a fallback for cdn_image_url — resizing real
  # images via Contentful is the bandwidth drain Cloudflare Images exists to avoid.
  # @see https://www.contentful.com/developers/docs/references/images-api/
  # @param original_url [String] The original URL of the image.
  # @param params [Hash] (Optional) Transformation parameters (:w, :h, :fm, :fit).
  # @return [String] The Contentful image URL with the parameters merged in.
  def contentful_image_url(original_url, params = {})
    params = params.dup
    params[:fit] = 'fill' if params[:fit] == 'cover'
    # Contentful has no format=auto; drop it and let it serve the source format.
    params.delete(:fm) if params[:fm].to_s == 'auto'
    merge_query(original_url, params)
  end

  # Merges query parameters into a URL, preserving (and overriding) any it already carries.
  # @param url [String] The URL.
  # @param params [Hash] The parameters to merge in.
  # @return [String] The URL with the merged query string.
  def merge_query(url, params)
    uri = URI.parse(url)
    existing_params = URI.decode_www_form(uri.query || "").to_h
    uri.query = URI.encode_www_form(existing_params.merge(params))
    uri.to_s
  end

  # Generates a responsive srcset for an image URL with specified widths and optional parameters.
  # @param url [String] The URL of the image.
  # @param widths [Array<Integer>] An array of image widths for the srcset.
  # @param square [Boolean] (Optional) Indicates if the image should be squared. Default is false.
  # @param options [Hash] (Optional) Additional query parameters to include in the srcset.
  # @return [String] The responsive srcset for the image.
  def srcset(url:, widths:, square: false, options: {})
    srcset = widths.map do |w|
      query = options.merge({ w: w })
      query.merge!({ h: w, fit: 'cover' }) if square
      cdn_image_url(url, query) + " #{w}w"
    end
    srcset.join(', ')
  end

  # Generates a CDN URL for an Open Graph image based on Facebook's size guidelines.
  # Deliberately centre-cropped: Cloudflare's gravity=auto picks the crop by saliency, but on
  # these photos it's unpredictable, and a boring crop beats a surprising one.
  # @param original_url [String] The original URL of the image.
  # @return [String] The CDN URL for the Open Graph image.
  def open_graph_image_url(original_url)
    params = { w: 1200, h: 630, fit: 'cover' }
    cdn_image_url(original_url, params)
  end

  # Bumped after a change to the card design or logo. It's folded into the `v` cache buster
  # below, so bumping it re-mints every card URL and refreshes the year-cached images (the
  # kona-og service and Cloudflare otherwise treat each card URL as immutable). The matching
  # card template lives in the og/ service.
  OG_TEMPLATE_VERSION = 'v1'

  # Returns the URL of the on-demand Open Graph card for the given page. The kona-og service
  # (the og/ app) fetches the page, reads its own og:title, and renders a 1200×630 PNG cached
  # for a year. The card URL is content-addressed: `v` combines OG_TEMPLATE_VERSION with the
  # entry's published_version, so a republish (which bumps published_version) mints a new URL
  # and a title edit is picked up on the next crawl — no cache purge needed.
  #
  # OG_IMAGE_URL is optional: when it's unset the kona-og service isn't wired up, so this returns
  # nil and callers omit the card rather than failing the build. Cover-image OG images
  # (open_graph_image_url) don't depend on it, so those pages keep their social image.
  # @param url [String] The full URL of the page to render a card for.
  # @param version [Integer, String, nil] The entry's sys.published_version, used as a cache
  #   buster. Listing pages (the blog index, tag archives) aren't Contentful entries and have no
  #   published_version, so it may be nil — the card then busts on OG_TEMPLATE_VERSION alone,
  #   which is correct since their og:title is static.
  # @return [String, nil] The kona-og URL for the page's card, or nil if OG_IMAGE_URL is unset.
  def generate_open_graph_image_url(url, version = nil)
    base = ENV['OG_IMAGE_URL'].to_s.chomp('/')
    return if base.blank?
    v = version.present? ? "#{OG_TEMPLATE_VERSION}-#{version}" : OG_TEMPLATE_VERSION
    query = URI.encode_www_form(url: url, v: v)
    "#{base}/og.png?#{query}"
  end

  # Generates a CDN URL for the site icon with the specified width.
  # @param w [Integer] The desired width of the site icon.
  # @return [String, nil] The CDN URL for the site icon with the specified width, or nil if not found.
  # @raise [ImagesUrlMissing] if IMAGES_URL is unset.
  def site_icon_url(w:)
    original_url = data.site.logo.url
    cdn_image_url(original_url, { w: w })
  rescue ImagesUrlMissing
    # A misconfigured build must fail, not silently lose the icon; the rescue below is only
    # here for a site entry that has no logo at all.
    raise
  rescue StandardError
    nil
  end

  # Generates a data URI containing an SVG embedded with the Blurhash for an asset ID.
  # @see https://css-tricks.com/the-blur-up-technique-for-loading-background-images/#recreating-the-blur-filter-with-svg
  # @param asset_id [String] The ID of the asset used for generating Blurhash SVG.
  # @return [String, nil] The data URI with SVG data for Blurhash, or nil if not found or blank.
  def blurhash_svg_data_uri(asset_id)
    svg = blurhash_svg(asset_id)
    return if svg.blank?

    encoded_svg = ERB::Util.url_encode(svg.gsub(/\s+/, ' '))
    "data:image/svg+xml;charset=utf-8,#{encoded_svg}"
  end

  # Generates an SVG embedded with the Blurhash for an asset ID.
  # @param asset_id [String] The ID of the asset used for generating Blurhash SVG.
  # @return [String, nil] The SVG with Blurhash effect, or nil if not found or blank.
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

  # Generates a data URI containing JPEG image data for the Blurhash for an an asset ID.
  # @param asset_id [String] The ID of the asset used for generating Blurhash JPEG data URI.
  # @param width [Integer] (Optional) The desired width of the JPEG image. Default is 32.
  # @return [String, nil] The data URI with JPEG image data and Blurhash effect, or nil if not generated or valid.
  def blurhash_jpeg_data_uri(asset_id, width: 32)
    content_type = get_asset_content_type(asset_id)
    # Blurhashes for GIFs are not supported; return.
    return if content_type == 'image/gif'

    original_width, original_height = get_asset_dimensions(asset_id)
    published_version = get_asset_published_version(asset_id)
    return unless original_width && original_height && published_version

    # Attempt to fetch from cache—generating these things is sorta expensive
    cache_key = "blurhash:jpeg:#{asset_id}:#{published_version}:#{width}"
    jpeg = redis.get(cache_key)
    return jpeg if jpeg.present?

    # Attempt to encode the Blurhash string
    height = ((original_height.to_f / original_width.to_f) * width).round
    blurhash = encode_blurhash(asset_id, width, height)
    return unless Blurhash.valid_blurhash?(blurhash)

    # Generate the JPEG image from the Blurhash string. Blurhash decodes to opaque RGBA,
    # so the alpha band is dropped rather than composited.
    pixels = Blurhash.decode(width, height, blurhash)
    image = Vips::Image.new_from_memory(pixels.pack('C*'), width, height, 4, :uchar)
                       .copy(interpretation: :srgb)
                       .extract_band(0, n: 3)

    # Encode the JPEG image as a data URI
    jpeg = "data:image/jpeg;base64,#{Base64.strict_encode64(image.write_to_buffer('.jpg'))}"

    # Cache that shit for later.
    redis.set(cache_key, jpeg)
    jpeg
  rescue StandardError => e
    warn "Blurhash JPEG generation failed for asset #{asset_id}: #{e.message}"
    nil
  end

  # Encodes a Blurhash using libvips for an asset based on its ID, width, and height.
  # Downloads the thumbnail straight from Contentful rather than through our own CDN, so the
  # build doesn't depend on the zone being up — or on Cloudflare's transformation quota, which
  # this would otherwise spend a slot of per asset. It's cheap: the thumbnails are 32px wide,
  # and blurhash_jpeg_data_uri caches the result in Redis per published version.
  # @param asset_id [String] The ID of the asset used for generating the Blurhash.
  # @param width [Integer] The width of the Blurhash image.
  # @param height [Integer] The height of the Blurhash image.
  # @return [String, nil] The generated Blurhash, or nil if not generated
  def encode_blurhash(asset_id, width, height)
    url = get_asset_url(asset_id)
    data = URI.open(contentful_image_url(url, { w: width, h: height })).read
    image = Vips::Image.new_from_buffer(data, '').colourspace(:srgb)
    image = image.flatten if image.has_alpha?
    Blurhash.encode(image.width, image.height, image.to_a.flatten)
  rescue StandardError => e
    warn "Blurhash encoding failed for asset #{asset_id}: #{e.message}"
    nil
  end
end
