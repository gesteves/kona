require 'mini_magick'
require 'httparty'
require 'base64'
require 'blurhash'
require 'erb'

module ImageHelpers
  # Extracts the asset ID from a URL.
  # @param url [String] The URL from which to extract the asset ID.
  # @return [String] The asset ID extracted from the URL.
  def get_asset_id(url)
    url.split('/')[4]
  end

  # Retrieves the dimensions (width and height) of an asset by its ID.
  # @param asset_id [String] The ID of the asset for which to retrieve dimensions.
  # @return [Integer, Integer] The width and height of the asset, or nil if the asset is not found.
  def get_asset_dimensions(asset_id)
    asset = data.assets.find { |a| a.sys.id == asset_id }
    return asset&.width, asset&.height
  end

  # Retrieves the description of an asset by its ID.
  # @param asset_id [String] The ID of the asset for which to retrieve the description.
  # @return [String, nil] The description of the asset, or nil if the asset is not found or has no description.
  def get_asset_description(asset_id)
    asset = data.assets.find { |a| a.sys.id == asset_id }
    asset&.description&.strip
  end

  # Retrieves the content type of an asset by its ID.
  # @param asset_id [String] The ID of the asset for which to retrieve the content type.
  # @return [String, nil] The content type of the asset, or nil if the asset is not found.
  def get_asset_content_type(asset_id)
    asset = data.assets.find { |a| a.sys.id == asset_id }
    asset&.contentType
  end

  # Retrieves the URL of an asset by its ID.
  # @param asset_id [String] The ID of the asset for which to retrieve the URL.
  # @return [String, nil] The URL of the asset, or nil if the asset is not found.
  def get_asset_url(asset_id)
    asset = data.assets.find { |a| a.sys.id == asset_id }
    asset&.url
  end

  # Generates a CDN image URL with optional query parameters.
  # @param original_url [String] The original URL of the image.
  # @param params [Hash] (Optional) Query parameters to be appended to the URL.
  # @return [String] The CDN image URL with optional query parameters.
  def cdn_image_url(original_url, params = {})
    # For some reason sometimes contentful returns an asset served from downloads.ctfassets.net,
    # which aren't served from their CDN, and break image processing.
    original_url.sub!('downloads.ctfassets.net', 'images.ctfassets.net')

    if ENV['NETLIFY'] == 'true'
      base_path = '/.netlify/images'
      netlify_base_url = ENV['CONTEXT'] == 'dev' ? "http://localhost:8888#{base_path}" : "#{ENV['URL']}#{base_path}"
      original_url = "https:#{original_url}" if original_url.start_with?('//')

      query_params = URI.encode_www_form(params)
      url_with_params = "#{netlify_base_url}?url=#{URI.encode_www_form_component(original_url)}"
      url_with_params += "&#{query_params}" unless query_params.empty?
    else
      query_params = URI.encode_www_form(params)
      url_with_params = original_url
      url_with_params += "?#{query_params}" unless query_params.empty? || original_url.include?('?')
    end

    url_with_params
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

  # Generates a CDN URL for an Open Graph image with specified dimensions.
  # @param original_url [String] The original URL of the image.
  # @return [String] The CDN URL for the Open Graph image with specified dimensions.
  def open_graph_image_url(original_url)
    params = { w: 1200, h: 630, fit: 'cover' }
    cdn_image_url(original_url, params)
  end

  # Generates a CDN URL for the site icon with the specified width.
  # @param w [Integer] The desired width of the site icon.
  # @return [String, nil] The CDN URL for the site icon with the specified width, or nil if not found.
  def site_icon_url(w:)
    original_url = data.site.logo.url
    cdn_image_url(original_url, { w: w })
  rescue
    nil
  end

  # Generates a data URI containing SVG data for Blurhash based on an asset ID.
  # https://css-tricks.com/the-blur-up-technique-for-loading-background-images/#recreating-the-blur-filter-with-svg
  # @param asset_id [String] The ID of the asset used for generating Blurhash SVG.
  # @return [String, nil] The data URI with SVG data for Blurhash, or nil if not found or blank.
  def blurhash_svg_data_uri(asset_id)
    svg = blurhash_svg(asset_id)
    return if svg.blank?

    encoded_svg = ERB::Util.url_encode(svg.gsub(/\s+/, ' '))
    "data:image/svg+xml;charset=utf-8,#{encoded_svg}"
  end

  # Generates an SVG with Blurhash effect based on an asset ID.
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

  # Generates a data URI containing JPEG image data with Blurhash effect based on an asset ID.
  # @param asset_id [String] The ID of the asset used for generating Blurhash JPEG data URI.
  # @param width [Integer] (Optional) The desired width of the JPEG image. Default is 32.
  # @return [String, nil] The data URI with JPEG image data and Blurhash effect, or nil if not generated or valid.
  def blurhash_jpeg_data_uri(asset_id, width: 32)
    return unless ENV['ENABLE_BLURHASH'].present?

    original_width, original_height = get_asset_dimensions(asset_id)
    return unless original_width && original_height

    height = ((original_height.to_f / original_width.to_f) * width).round
    blurhash = generate_blurhash(asset_id, width, height)
    return unless Blurhash.valid_blurhash?(blurhash)

    pixels = Blurhash.decode(width, height, blurhash)
    depth = 8
    dimensions = [width, height]
    map = 'rgba'
    image = MiniMagick::Image.get_image_from_pixels(pixels, dimensions, map, depth, 'jpg')
    "data:image/jpeg;base64,#{Base64.strict_encode64(image.to_blob)}"
  rescue => e
    STDERR.puts "Blurhash data URI generation error: #{e.message}"
    nil
  end

  # Generates a Blurhash for an asset based on its ID, width, and height.
  # @param asset_id [String] The ID of the asset used for generating Blurhash.
  # @param width [Integer] The width of the Blurhash image.
  # @param height [Integer] The height of the Blurhash image.
  # @return [String, nil] The generated Blurhash, or nil if not generated or retrieved.
  def generate_blurhash(asset_id, width, height)
    url = get_asset_url(asset_id)
    blurhash_url = cdn_image_url(url, { fm: 'blurhash', w: width, h: height })
    response = HTTParty.get(blurhash_url)
    response.ok? ? response.body : nil
  rescue
    nil
  end
end
