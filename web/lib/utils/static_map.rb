require 'httparty'
require 'nokogiri'
require 'fileutils'
require 'active_support/all'
require_relative 'mapbox_tileset'

class StaticMap
  attr_accessor :tileset_id

  GPX_FOLDER = File.expand_path('../../../data/maps/gpx', __FILE__)
  IMAGES_FOLDER = File.expand_path('../../../data/maps/images', __FILE__)

  MAPBOX_ACCESS_TOKEN = ENV['MAPBOX_ACCESS_TOKEN'] || raise('Mapbox access token is missing!')
  MAPBOX_STYLE_URL = ENV['MAPBOX_STYLE_URL'] || "mapbox://styles/mapbox/outdoors-v12"

  # The render request uses the secret token when present so it can read the
  # private tilesets uploaded via MTS; it falls back to the public access token
  # (e.g. the manual TILESET_ID override against a public tileset).
  RENDER_TOKEN = ENV['MAPBOX_SECRET_TOKEN'].presence || MAPBOX_ACCESS_TOKEN

  # Maki icons
  # @see https://labs.mapbox.com/maki-icons/
  ACTIVITY_ICONS = {
    running: 'pitch',
    cycling: 'bicycle-share',
    swimming: 'swimming',
    start: 'rocket',
    finish: 'racetrack',
    dnf: 'danger'
  }

  START_MARKER_COLOR = '18A644' # Green
  END_MARKER_COLOR = 'F90F1A' # Red

  TRACK_COLOR = 'BF0222' # Red
  TRACK_OPACITY = 0.75
  TRACK_WIDTH = 4

  WIDTH = 1280
  MAX_HEIGHT = 1280
  MIN_HEIGHT = 800
  PADDING = 50
  MIN_KM = 0  # Default kilometers added to each side of the map's viewable area

  # Approximate length of one degree of latitude in kilometers. One degree of
  # longitude is this value scaled by the cosine of the latitude.
  KM_PER_DEGREE = 111.32

  # Defaults for the image download HTTP request.
  HTTP_TIMEOUT = 30      # seconds
  HTTP_MAX_ATTEMPTS = 3

  def initialize(gpx_file_path, options = {})
    options = options.reverse_merge(
      min_km: MIN_KM,
      padding: PADDING,
      reverse_markers: false,
      dnf: false
    )

    @tileset_id = options[:tileset_id]
    # Source-layer defaults to the legacy name for the manual override path; an
    # auto-upload resets it to MapboxTileset::LAYER_NAME once the tileset exists.
    @source_layer = ENV['SOURCE_LAYER'].presence || 'tracks'
    # Per-side margins (km) added to the bounding box, in CSS "top,right,bottom,left"
    # shorthand — e.g. "2,0,0,0" adds 2 km of map above the track.
    @margins_km = parse_box_shorthand(options[:min_km], default: MIN_KM, cast: :to_f)
    @padding = validate_padding(options[:padding])
    @reverse_markers = options[:reverse_markers]
    @dnf = options[:dnf]
    @force_upload = options[:force_upload]
    extract_data_from_gpx(gpx_file_path)
    @bounding_box = calculate_bounding_box(@coordinates)
    @width = WIDTH
    @height = if options[:height].to_i > top_and_bottom_padding(@padding)
      options[:height].to_i.clamp(MIN_HEIGHT, MAX_HEIGHT)
    else
      (@width / bounding_box_aspect_ratio(@bounding_box)).ceil.clamp(MIN_HEIGHT, MAX_HEIGHT)
    end
  end

  # Generates a map as a static image and saves it to the IMAGES_FOLDER folder.
  def generate_image!
    ensure_tileset!
    puts "🔄 Generating map for #{activity_title}"
    output_file_path = File.join(IMAGES_FOLDER, image_file_name)
    image_url = mapbox_image_url

    puts "💾 Saving image…"
    download_image(image_url, output_file_path)
    puts "✅ Image saved to #{image_file_name}\n\n"
  end

  # Returns a title for the activity based on the GPX file name and activity type.
  # @return [String] The title for the activity
  def activity_title
    year = @activity_start&.strftime('%Y')
    title = year.present? ? "#{year} #{@activity_name.gsub(/#{year}/, '').strip}" : @activity_name
    return title if title =~ /swim|run|bike|biking|cycling|marathon|5k|10k|10-miler|ten-miler|carrera/i
    "#{title} - #{@activity_type}"
  end

  # Ensures a Mapbox tileset exists for this track. When no tileset_id was
  # provided, reuses the existing tileset if one is already published (so tweaking
  # render-time image settings doesn't re-upload), otherwise uploads the GPX
  # coordinates to Mapbox as a private tileset (via MTS). Pass force_upload to
  # always re-upload (e.g. when the GPX itself changed).
  def ensure_tileset!
    return if @tileset_id.present?

    uploader = MapboxTileset.new(
      username: ENV['MAPBOX_USERNAME'],
      token: ENV['MAPBOX_SECRET_TOKEN']
    )
    id = tileset_source_id

    if !@force_upload && (existing = uploader.find(id))
      @tileset_id, @source_layer = existing
      puts "♻️  Reusing existing Mapbox tileset for #{activity_title}…"
      return
    end

    puts "⬆️  Uploading #{activity_title} to Mapbox…"
    @tileset_id = uploader.create_from_coordinates!(
      id: id,
      name: activity_title,
      coordinates: @coordinates
    )
    @source_layer = MapboxTileset::LAYER_NAME
  end

  private

  # Derives a Mapbox-safe tileset/source id from the activity title: the id is
  # capped at 32 characters and may only contain letters, numbers, `-`, and `_`.
  def tileset_source_id
    activity_title.parameterize.tr('-', '_').first(32).gsub(/_+$/, '')
  end

  # Returns the file name for the map image based on the activity title
  # @return [String] The file name for the map image
  def image_file_name
    activity_title.parameterize + '.png'
  end

  # Extracts data from a GPX file and saves it in instance variables.
  # @param gpx_file_path [String] The path to the GPX file
  def extract_data_from_gpx(gpx_file_path)
    raise "GPX file not found: #{gpx_file_path}" unless File.exist?(gpx_file_path)

    doc = Nokogiri::XML(File.open(gpx_file_path))
    @activity_name = doc.at_xpath('//xmlns:trk/xmlns:name')&.text || File.basename(gpx_file_path)
    @activity_type = doc.at_xpath('//xmlns:trk/xmlns:type')&.text&.titleize || 'Other'
    @activity_start = begin
      DateTime.parse(doc.at_xpath('//xmlns:trkpt[1]/xmlns:time')&.text)
    rescue
      nil
    end

    @coordinates = doc.xpath('//xmlns:trkpt').map do |trkpt|
      [trkpt['lon'].to_f, trkpt['lat'].to_f]
    end

    raise 'No track points found in GPX file' if @coordinates.empty?
  end

  # Calculates the bounding box for a set of coordinates, taking latitude into account.
  # @param coordinates [Array<Array<Float>>] The coordinates of the track points
  # @return [Hash] The bounding box with min_lon, max_lon, min_lat, and max_lat
  def calculate_bounding_box(coordinates)
    # Separate the longitudes and latitudes from the coordinates
    lons, lats = coordinates.transpose
    min_lon, max_lon = lons.min, lons.max
    min_lat, max_lat = lats.min, lats.max

    # Calculate the average latitude (center of the bounding box in terms of latitude)
    center_lat = (min_lat + max_lat) / 2

    # The cosine of the latitude adjusts the length of one degree of longitude.
    # At the equator (latitude 0°), cos(0) = 1, so 1° of longitude is approximately KM_PER_DEGREE km.
    # As you move toward the poles, cos(latitude) decreases, making longitude degrees shorter.
    cos = cos_lat(center_lat)

    # Expand the bounding box outward by the per-side margins (in km), converting
    # each km offset to degrees. 1° of latitude ≈ KM_PER_DEGREE km everywhere;
    # 1° of longitude ≈ KM_PER_DEGREE km * cos(latitude).
    top_km, right_km, bottom_km, left_km = @margins_km
    max_lat += top_km / KM_PER_DEGREE
    min_lat -= bottom_km / KM_PER_DEGREE
    max_lon += right_km / (KM_PER_DEGREE * cos)
    min_lon -= left_km / (KM_PER_DEGREE * cos)

    {
      min_lon: min_lon,
      max_lon: max_lon,
      min_lat: min_lat,
      max_lat: max_lat
    }
  end

  # Calculates the aspect ratio of the bounding box based on physical distances in kilometers.
  # @param bounding_box [Hash] The bounding box with min_lon, max_lon, min_lat, and max_lat
  # @return [Float] The aspect ratio (width in km / height in km)
  def bounding_box_aspect_ratio(bounding_box)
    center_lat = (bounding_box[:min_lat] + bounding_box[:max_lat]) / 2

    # Convert the differences in longitude and latitude to kilometers
    width_km = (bounding_box[:max_lon] - bounding_box[:min_lon]) * KM_PER_DEGREE * cos_lat(center_lat)
    height_km = (bounding_box[:max_lat] - bounding_box[:min_lat]) * KM_PER_DEGREE

    # Calculate the aspect ratio as width in km divided by height in km, guarding
    # against a zero/degenerate span so the caller can fall back to a clamped height.
    ratio = width_km / height_km
    ratio.finite? && ratio.positive? ? ratio : 1.0
  end

  # Returns the cosine of a latitude given in degrees, used to scale the length
  # of a degree of longitude at that latitude.
  # @param latitude [Float] The latitude in degrees
  # @return [Float] The cosine of the latitude
  def cos_lat(latitude)
    Math.cos(latitude * Math::PI / 180)
  end

  # Generates the URL for a static map image from Mapbox.
  # @return [String] The URL for the static map image
  # @see https://docs.mapbox.com/api/maps/static-images/
  def mapbox_image_url
    username, style = MAPBOX_STYLE_URL.split('/')[3..4]
    markers = [marker_config(:end_marker, @coordinates.last), marker_config(:start_marker, @coordinates.first)]
    markers.reverse! if @reverse_markers
    bbox = "%5B#{@bounding_box[:min_lon]},#{@bounding_box[:min_lat]},#{@bounding_box[:max_lon]},#{@bounding_box[:max_lat]}%5D"
    layer = generate_layer

    base_params = {
      padding: @padding,
      access_token: RENDER_TOKEN
    }.compact

    url = "https://api.mapbox.com/styles/v1/#{username}/#{style}/static/#{markers.join(',')}/#{bbox}/#{@width}x#{@height}@2x?#{base_params.to_query}"
    url += "&addlayer=#{layer.to_json}&before_layer=road-label" if layer.present?
    url
  end

  # Generates the marker configuration for a Mapbox static map image.
  # @param marker_type [Symbol] The type of marker (:start_marker or :end_marker)
  # @param coordinate [Array<Float>] The coordinate of the marker
  # @return [String] The marker configuration
  def marker_config(marker_type, coordinate)
    color = marker_type == :start_marker ? START_MARKER_COLOR : END_MARKER_COLOR
    icon = select_icon(marker_type)

    "pin-l-#{icon}+#{color}(#{coordinate[0]},#{coordinate[1]})"
  end

  # Selects the icon for a marker based on the marker type and the activity type.
  # @param marker_type [Symbol] The type of marker (:start_marker or :end_marker)
  # @return [String] The icon name
  def select_icon(marker_type)
    return ACTIVITY_ICONS[:dnf]      if @dnf && marker_type == :end_marker
    return ACTIVITY_ICONS[:finish]   if marker_type == :end_marker

    return ACTIVITY_ICONS[:swimming] if @activity_type =~ /swimming/i
    return ACTIVITY_ICONS[:cycling]  if @activity_type =~ /cycling|biking/i
    return ACTIVITY_ICONS[:running]  if @activity_type =~ /running/i

    ACTIVITY_ICONS[:start]
  end

  # Downloads an image from a URL and saves it to a file.
  # @param image_url [String] The URL of the image to download
  # @param output_file_path [String] The path to save the image
  def download_image(image_url, output_file_path)
    response = get_with_retries(image_url)

    raise error_message_from(response) unless response.success?

    FileUtils.mkdir_p(File.dirname(output_file_path))
    File.open(output_file_path, 'wb') { |f| f.write(response.body) }
  end

  # Performs an HTTP GET with a timeout, retrying a bounded number of times on
  # transient failures (network errors or 5xx responses).
  # @param url [String] The URL to fetch
  # @return [HTTParty::Response] The HTTP response
  def get_with_retries(url)
    attempt = 0
    begin
      attempt += 1
      response = HTTParty.get(url, timeout: HTTP_TIMEOUT)
      return response if response.success? || response.code < 500 || attempt >= HTTP_MAX_ATTEMPTS
      raise "Mapbox returned status #{response.code}"
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, HTTParty::Error, RuntimeError => e
      raise e if attempt >= HTTP_MAX_ATTEMPTS
      sleep(attempt)
      retry
    end
  end

  # Builds a human-readable error message from a failed Mapbox response,
  # falling back to the status code when the body isn't JSON.
  # @param response [HTTParty::Response] The failed HTTP response
  # @return [String] The error message
  def error_message_from(response)
    message = begin
      JSON.parse(response.body, symbolize_names: true)[:message]
    rescue JSON::ParserError, TypeError
      nil
    end
    message.presence || "Mapbox request failed with status #{response.code}"
  end

  # Validates the padding value, normalizing it to a Mapbox "top,right,bottom,left"
  # string regardless of how many values were provided.
  # @param padding [String, Integer] The padding value
  # @return [String] The normalized "top,right,bottom,left" padding
  def validate_padding(padding)
    parse_box_shorthand(padding, default: PADDING, cast: :to_i).join(',')
  end

  # Expands a CSS-style "top,right,bottom,left" shorthand into a 4-element
  # [top, right, bottom, left] array, accepting 1–4 comma-separated values using
  # the same rules as CSS and falling back to `default` on all sides.
  # @param value [String, Numeric] The shorthand value
  # @param default [Numeric] Value applied to all sides when nothing parses
  # @param cast [Symbol] How to coerce each value (:to_i or :to_f)
  # @return [Array<Numeric>] [top, right, bottom, left]
  def parse_box_shorthand(value, default:, cast: :to_f)
    values = value.to_s.split(',').map(&:strip).reject(&:empty?).map(&cast).first(4)

    case values.length
    when 1  # Single value: apply to all sides
      [values[0]] * 4
    when 2  # Two values: top/bottom, left/right
      [values[0], values[1], values[0], values[1]]
    when 3  # Three values: top, left/right, bottom
      [values[0], values[1], values[2], values[1]]
    when 4  # Four values: top, right, bottom, left
      values
    else
      [default] * 4  # Default applied to all sides on empty input
    end
  end

  # Calculates the sum of the top and bottom padding.
  # @param padding [String] The normalized "top,right,bottom,left" padding
  # @return [Integer] The total padding
  def top_and_bottom_padding(padding)
    top, _right, bottom, _left = padding.to_s.split(',').map(&:to_i)
    top.to_i + bottom.to_i
  end

  # Generates a layer for a Mapbox tileset, which should be the GPX file uploaded to Mapbox.
  # @return [Hash] The layer configuration
  def generate_layer
    return if @tileset_id.blank?
    {
      "id": @tileset_id,
      "type": "line",
      "source": {
        "type": "vector",
        "url": "mapbox://#{@tileset_id}"
      },
      "source-layer": @source_layer,
      "paint": {
        "line-color": URI.encode_www_form_component("##{TRACK_COLOR}"),
        "line-width": TRACK_WIDTH,
        "line-opacity": TRACK_OPACITY,
        "line-cap": "round",
        "line-join": "round"
      }
    }
  end
end

