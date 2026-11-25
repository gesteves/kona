require "erb"
require "zlib"

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

  # Gets the Contentful asset ID from an asset URL.
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

  # @return [Array<Integer, Integer>] The width and the height of the asset, or nils if unknown.
  def get_asset_dimensions(asset_id)
    asset = asset_index[asset_id]
    return asset&.width, asset&.height
  end

  # @return [String, nil] The description of the asset (its alt text), or nil if it has none.
  def get_asset_description(asset_id)
    asset = asset_index[asset_id]
    asset&.description&.strip
  end

  # @return [String, nil] The content type of the asset, or nil if the app cannot find it.
  def get_asset_content_type(asset_id)
    asset = asset_index[asset_id]
    asset&.content_type
  end

  # ⚠️ A GIF gets no transformation and no srcset, thus it keeps its animation. A width makes
  # Cloudflare give one static frame of it. Each image method reads this rule here.
  def gif_asset?(asset_id)
    get_asset_content_type(asset_id) == "image/gif"
  end

  # @return [String, nil] The URL of the asset, or nil if the app cannot find it.
  def get_asset_url(asset_id)
    asset = asset_index[asset_id]
    asset&.url
  end

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
    "#{ENV['IMAGES_URL'].chomp('/')}#{CDN_IMAGE_PATH}#{cdn_image_options(params)}/#{original_url}"
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

  # Makes the value of a responsive srcset attribute.
  # @param widths [Array<Integer>] The widths to make candidates for.
  # @param ratio [Numeric, nil] The height of a candidate divided by its width. It cuts each
  #   candidate to that shape. Nil keeps the shape of the asset.
  # @param options [Hash] More transformation parameters.
  def srcset(url:, widths:, ratio: nil, options: {})
    srcset = widths.map do |w|
      query = options.merge({ w: w })
      query.merge!({ h: candidate_height(w, ratio), fit: "cover" }) if ratio
      cdn_image_url(url, query) + " #{w}w"
    end
    srcset.join(", ")
  end

  # @param ratio [Numeric] The height divided by the width.
  # @return [Integer] The height of the candidate.
  def candidate_height(width, ratio)
    (width * ratio).round
  end

  # The shape of a cover image on a card: the height divided by the width. It comes from the
  # `ratio` of a card variant of data/srcsets.yml, which is the one place in web/ that holds the
  # shape. api/config/srcsets.yml is a copy, and a person keeps the two the same.
  # @param variant [Symbol] The name of the card variant.
  # @return [Rational]
  def card_ratio(variant = :card)
    w, h = data.srcsets.public_send(variant).ratio.split(":", 2).map(&:to_i)
    Rational(h, w)
  end

  # The same shape in the CSS form: it changes the colon into a slash. `cover_image_tag` and the
  # entry skeleton write it into the markup as `--card-ratio`, and _entry.scss and _skeleton.scss
  # read it. Thus the stylesheets follow srcsets.yml, and a person does not edit the shape in two
  # languages.
  # @return [String]
  def card_aspect_ratio(variant = :card)
    data.srcsets.public_send(variant).ratio.sub(":", " / ")
  end

  # Makes the <img> of the cover image of an entry, for a card.
  #
  # ⚠️ It gives the element `alt=""`, and the caller must put it in a link with `aria-hidden="true"`
  # and `tabindex="-1"`. The headline below the image links to the same page, thus without that,
  # each card gives a screen reader two identical links and two identical tab stops.
  # @param variant [Symbol] The name of the card variant in data/srcsets.yml.
  # @param eager [Boolean] True to ask for the LCP mark. Refer to the note below.
  # @return [String] The <img> element, or an empty string when the entry has no cover image.
  def cover_image_tag(entry, variant: :card, eager: false)
    cover = entry&.cover_image
    return "" if cover&.url.blank?

    asset_id = get_asset_id(cover.url)
    config = data.srcsets.public_send(variant)
    widths = card_widths(config.widths, cover.width)
    # The first width of a variant is its 1x size at the largest breakpoint. Each other candidate
    # is for a smaller viewport or a denser screen. Thus it is the correct src.
    width = [ config.widths.first, widths.max ].min
    height = candidate_height(width, card_ratio(variant))

    # ⚠️ `eager` is a request and not a command: only the FIRST image of the page gets the mark.
    # Thus a caller can pass it for each card of a list. Refer to MarkupImageHelpers#claim_lcp_image.
    lcp = eager && claim_lcp_image

    gif = gif_asset?(asset_id)
    # ⚠️ The src must be one of the candidates below, word for word, and `fm` is part of that.
    # Cloudflare renders and bills one transformation for each different URL, thus a src that only
    # looks the same is a second render of each cover image that no browser uses.
    src_query = { fm: "auto", w: width, h: height, fit: "cover" }

    attributes = {
      src: gif ? cdn_image_url(cover.url) : cdn_image_url(cover.url, src_query),
      width: width,
      height: height,
      alt: "",
      # `loading="lazy"` is necessary, because each sizes list starts with `auto`. Refer to the
      # note at `sizes` below.
      loading: lcp ? "eager" : "lazy",
      decoding: "async",
      class: "entry__cover-image placeholder",
      "data-controller": "image-placeholder",
      "data-action": "load->image-placeholder#removePlaceholder error->image-placeholder#removePlaceholder"
    }

    attributes[:fetchpriority] = "high" if lcp

    # ⚠️ The shape goes in the markup, and not in the stylesheet. _entry.scss reads --card-ratio,
    # thus data/srcsets.yml is the one place in web/ that holds it (refer to #card_ratio). Keep the
    # placeholder in the SAME attribute: a second style attribute would replace this one.
    style = [ "--card-ratio:#{card_aspect_ratio(variant)};" ]
    placeholder = blurhash_svg_data_uri(asset_id)
    style << "--placeholder:url('#{placeholder}');" if placeholder.present?
    attributes[:style] = style.join

    unless gif
      # ⚠️ An eager image must not have `auto` in its `sizes`: refer to the `home` variant of
      # data/srcsets.yml. Thus the eager card drops it and uses the media conditions after it,
      # which are complete without it.
      sizes = lcp ? config.sizes.reject { |s| s == "auto" } : config.sizes
      attributes[:sizes] = sizes.join(", ")
      attributes[:srcset] = srcset(url: cover.url, widths: widths, ratio: card_ratio(variant), options: { fm: "auto" })
    end

    tag(:img, attributes)
  end

  # The candidate widths of an image, for a card and for a body image. It removes each width above
  # the width of the asset, because Cloudflare does not make an image larger than its source.
  # @param widths [Array<Integer>] The widths of the variant.
  # @param asset_width [Integer, nil] The width of the asset.
  # @return [Array<Integer>] The widths, in order, with no duplicate.
  def card_widths(widths, asset_width)
    candidates = widths.dup
    # A width of 0 is present, and it would leave [0] as the only candidate.
    if asset_width.to_i.positive?
      candidates << asset_width if asset_width < candidates.max
      candidates = candidates.reject { |w| w > asset_width }
    end
    candidates.uniq.sort
  end

  # Makes the Open Graph card URL for a cover image, at the size that Facebook recommends. It
  # cuts the image at the center, on purpose, because the Cloudflare saliency crop gives
  # unpredictable results on these photos.
  def open_graph_image_url(original_url)
    params = { w: 1200, h: 630, fit: "cover" }
    cdn_image_url(original_url, params)
  end

  # Increase this after you change the card design, the logo, or the font in web/src/og-render.ts.
  # It goes into the `v` cache buster below, thus an increase makes a new URL for each card. In
  # all other conditions a card is immutable.
  #
  # ⚠️ Keep the `v<number>` shape. src/og.ts checks `v` against /^v\d+(-\d+)?$/ before it makes the
  # cache key, thus a `?v=<random>` cannot start an unlimited number of renders. A value outside
  # that shape still renders, but each card then uses one cache entry, with no message.
  OG_TEMPLATE_VERSION = "v2"

  # Makes the URL of the on-demand Open Graph card for a page. The Worker of this site
  # (web/src/og.ts) renders the card from the og:title of the page. The card URL comes from the
  # path of the page, thus there is no path from a caller to check. The ".png" is important: it
  # keeps the route out of the zone Cache Rule (`not path contains "."`).
  #
  # ⚠️ A listing page needs the title. The Worker stores each card with the Cache API and writes no
  # `Cache-Tag`, thus do not trust the deploy purge to reach it. Without the title, the URL never
  # changes and a cache can keep an old card for a year.
  # @param path [String] The root-relative path of the page (current_page.url).
  # @param version [Integer, String, nil] The sys.published_version of the entry, thus a new
  #   publish makes a new URL. It is nil for a listing page, which is not a Contentful entry.
  # @param title [String, nil] The og:title of the page. With no version, a CRC32 of it addresses
  #   the card, thus a new title makes a new URL.
  # @return [String] The URL of the card.
  def generate_open_graph_image_url(path, version = nil, title: nil)
    v = if version.present?
      "#{OG_TEMPLATE_VERSION}-#{version}"
    elsif title.present?
      "#{OG_TEMPLATE_VERSION}-#{Zlib.crc32(title)}"
    else
      OG_TEMPLATE_VERSION
    end
    query = URI.encode_www_form(v: v)
    "#{root_url.to_s.chomp('/')}#{path.to_s.chomp('/')}/og.png?#{query}"
  end

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
end
