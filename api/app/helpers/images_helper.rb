require "yaml"

module ImagesHelper
  # The Cloudflare Images transformation path. The options go in the path, and not in the query
  # string.
  # @see https://developers.cloudflare.com/images/transform-images/transform-via-url/
  CDN_IMAGE_PATH = "/cdn-cgi/image/".freeze

  # ⚠️ Match each ctfassets host, and not only images.ctfassets.net. Contentful serves some image
  # assets from downloads.ctfassets.net. AssetMirror::ASSET_HOST_SUFFIX is the same rule on the
  # write side, and the two must match the same set.
  ASSET_HOST_SUFFIX = ".ctfassets.net".freeze

  # The shape of a cover image on a card: the height divided by the width, that is, 3:2.
  #
  # ⚠️ ImageHelpers::CARD_RATIO of the static site and .entry__cover-image in
  # web/source/stylesheets/components/_entry.scss must hold the same value. The two cards go on the
  # same page.
  CARD_RATIO = Rational(2, 3)

  # The `card` variant of config/srcsets.yml. ⚠️ That file is a copy of web/data/srcsets.yml, word
  # for word: the two cards go on the same page, thus a difference gives one image at the wrong
  # size in the middle of one section. The file gives the method that makes the widths, and
  # spec/contracts/srcsets_contract_spec.rb fails when the two copies are different.
  #
  # ⚠️ This reads the file one time, at the boot of the app, and `fetch` raises for a key that is
  # absent. Thus a file with a fault stops the deploy. That is on purpose, and it is not the same
  # as the rule below that `cdn_image_url` must never raise: that rule is about a REQUEST, where a
  # raise gives a 500 and leaves an empty skeleton on the page.
  CARD = YAML.load_file(Rails.root.join("config", "srcsets.yml")).fetch("card").freeze

  CARD_SIZES = CARD.fetch("sizes").join(", ").freeze

  # ⚠️ Keep the 1x desktop width first: `cover_image_tag` reads it for the `src`.
  CARD_WIDTHS = CARD.fetch("widths").map(&:to_i).freeze

  # The <img> of the cover image of an article card.
  #
  # ⚠️ It gives the element `alt=""`. The caller must put it in a link with `aria-hidden="true"`
  # and `tabindex="-1"`. The headline below the image already links to the same page, thus without
  # that, each card gives two identical tab stops and two identical entries in the link list of a
  # screen reader.
  # ⚠️ Keep this the same as ImageHelpers#cover_image_tag of the static site.
  # @param article [OpenStruct] The article.
  # @return [ActiveSupport::SafeBuffer, nil] The element, or nil when there is no image to render.
  def cover_image_tag(article)
    cover = article&.cover_image
    return if cover&.url.blank?

    widths = card_widths(cover.width)
    width = [ CARD_WIDTHS.first, widths.max ].min
    height = (width * CARD_RATIO).round
    # A GIF gets no transformation and no srcset: a transformation makes one static frame from it.
    gif = cover.content_type == "image/gif"
    # ⚠️ The src must be one of the candidates below, word for word, and `fm` is part of that.
    # Cloudflare renders and bills one transformation for each different URL, thus a src that only
    # looks the same is a second render of each cover image that no browser uses.
    src = gif ? cdn_image_url(cover.url) : cdn_image_url(cover.url, fm: "auto", w: width, h: height, fit: "cover")
    # No IMAGES_URL or no IMAGE_HOST. Render no image at all: a ctfassets URL gets a 403 as a
    # transformation source, and it uses the metered Contentful bandwidth as a direct src.
    return if src.blank?

    attributes = {
      src: src,
      width: width,
      height: height,
      alt: "",
      # `loading="lazy"` is necessary: the sizes list starts with `auto`, and a browser ignores
      # that keyword on an image that it loads at once.
      loading: "lazy",
      decoding: "async",
      class: "entry__cover-image placeholder",
      data: {
        controller: "image-placeholder",
        action: "load->image-placeholder#removePlaceholder error->image-placeholder#removePlaceholder"
      }
    }

    placeholder = blurhash_placeholder(cover)
    attributes[:style] = "--placeholder:url('#{placeholder}');" if placeholder.present?

    unless gif
      attributes[:sizes] = CARD_SIZES
      attributes[:srcset] = card_srcset(cover.url, widths)
    end

    tag.img(**attributes)
  end

  # Makes a Cloudflare Images transformation URL on IMAGES_URL, from the mirror copy of the asset.
  #
  # ⚠️ It returns nil when IMAGES_URL or IMAGE_HOST has no value, and it never raises. The static
  # site raises in the same condition, on purpose, because a raise there stops a bad deploy. A
  # raise here gives a 500, and the live-update controller then leaves an empty skeleton on the
  # page. Do not "correct" this into a raise.
  # @param url [String, nil] The Contentful URL of the asset.
  # @param params [Hash] The transformation parameters (:w, :h, :fm, :fit).
  # @return [String, nil] The transformation URL, or nil when the app cannot make one.
  def cdn_image_url(url, **params)
    source = mirror_url(url)
    return if source.blank? || ENV["IMAGES_URL"].blank?

    "#{ENV['IMAGES_URL'].chomp('/')}#{CDN_IMAGE_PATH}#{cdn_image_options(params)}/#{source}"
  end

  private

  # Changes the host of a Contentful asset URL to the R2 image mirror, and keeps the path.
  #
  # ⚠️ The path is the contract with the api side that writes the object, and with the static site.
  # Refer to AssetMirror#object_key. Never change the path.
  # @param url [String, nil] The Contentful URL of the asset.
  # @return [String, nil] The mirror URL, or nil for a blank URL, an unusable URL, or a host that
  #   is not ctfassets.
  def mirror_url(url)
    return if url.blank? || ENV["IMAGE_HOST"].blank?

    uri = URI.parse(url.to_s.start_with?("//") ? "https:#{url}" : url.to_s)
    return unless uri.host.to_s.end_with?(ASSET_HOST_SUFFIX)

    uri.scheme = "https"
    uri.host = ENV["IMAGE_HOST"]
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  # Changes the transformation parameters into the Cloudflare option string.
  # @param params [Hash] The transformation parameters (:w, :h, :fm, :fit).
  # @return [String] The options, in a fixed order.
  def cdn_image_options(params)
    options = []
    options << "format=#{params[:fm]}" if params[:fm].present?
    options << "width=#{params[:w]}" if params[:w].present?
    options << "height=#{params[:h]}" if params[:h].present?
    options << "fit=#{params[:fit]}" if params[:fit].present?
    # Cloudflare refuses a URL with no options. `anim=true` is the default, thus it does no
    # transformation.
    return "anim=true" if options.empty?

    options.join(",")
  end

  # @param url [String] The Contentful URL of the asset.
  # @param widths [Array<Integer>] The candidate widths.
  # @return [String] The srcset attribute value.
  def card_srcset(url, widths)
    widths.map do |w|
      "#{cdn_image_url(url, fm: 'auto', w: w, h: (w * CARD_RATIO).round, fit: 'cover')} #{w}w"
    end.join(", ")
  end

  # The candidate widths of a card image. It removes each width above the width of the asset,
  # because Cloudflare does not make an image larger than its source.
  # @param asset_width [Integer, nil] The width of the asset.
  # @return [Array<Integer>] The widths, in order, with no duplicate.
  def card_widths(asset_width)
    candidates = CARD_WIDTHS.dup
    if asset_width.present?
      candidates << asset_width if asset_width < candidates.max
      candidates = candidates.reject { |w| w > asset_width }
    end
    candidates.uniq.sort
  end

  # @param cover [OpenStruct] The cover image.
  # @return [String, nil] The data URI of the blurhash placeholder, or nil when there is none.
  def blurhash_placeholder(cover)
    BlurhashPlaceholder.new.read(cover.sys&.id, cover.sys&.published_version)
  end
end
