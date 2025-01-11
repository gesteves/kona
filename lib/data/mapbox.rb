require 'httparty'
require 'nokogiri'
require 'fileutils'
require 'active_support/all'

class Mapbox
  attr_writer :tileset_id

  GPX_FOLDER = File.expand_path('../../../data/mapbox/gpx', __FILE__)
  IMAGES_FOLDER = File.expand_path('../../../data/mapbox/images', __FILE__)

  MAPBOX_ACCESS_TOKEN = ENV['MAPBOX_ACCESS_TOKEN'] || raise('Mapbox API key is missing!')
  MAPBOX_STYLE_URL = ENV['MAPBOX_STYLE_URL'] || raise('Map style URL is missing!')

  ACTIVITY_ICONS = {
    running: 'pitch',
    cycling: 'bicycle-share',
    swimming: 'swimming',
    start: 'embassy',
    finish: 'racetrack'
  }

  START_MARKER_COLOR = '18A644'
  END_MARKER_COLOR = 'F90F1A'

  WIDTH = 1280
  MAX_HEIGHT = 1280
  MIN_HEIGHT = 800
  PADDING = 50
  MIN_SIZE = 0

  def initialize(
    gpx_file_path,
    options = {}
  )
    options.reverse_merge!(
      max_height: MAX_HEIGHT,
      min_size: MIN_SIZE,
      padding: PADDING
    )
    @gpx_file_path = gpx_file_path
    @max_height = [options[:max_height].to_i, MAX_HEIGHT].min
    @min_size = options[:min_size].to_i
    @padding = validate_padding(options[:padding])
    @tileset_id = options[:tileset_id]
    extract_data_from_gpx
  end

  # Generates a static map image from a GPX file, and saves it to the data/mapbox/images folder.
  # and then uses the Mapbox Static API to generate a static map image, but it doesn't add the GPX file to the map.
  # Before running this task, the GPX file must be uploaded to Mapbox and added to the map in Mapbox Studio first.
  def generate_map_image
    puts "🔄 Generating map for #{activity_title}"
    bounding_box = calculate_bounding_box(@coordinates)

    image_file_name = activity_title.parameterize + '.png'
    output_file_path = File.join(IMAGES_FOLDER, image_file_name)

    aspect_ratio = calculate_aspect_ratio(bounding_box)
    height = (WIDTH / aspect_ratio).clamp(MIN_HEIGHT, @max_height).round

    puts "💾 Saving image…"
    image_url = mapbox_image_url(bounding_box, @coordinates, WIDTH, height)
    download_image(image_url, output_file_path)
    puts "✅ Image saved to #{image_file_name}\n\n"
  end

  def activity_title
    return @activity_name if @activity_name.downcase.include?(@activity_type.downcase)
    "#{@activity_name} – #{@activity_type}"
  end

  private

  def extract_data_from_gpx
    doc = Nokogiri::XML(File.open(@gpx_file_path))
    @activity_name = doc.at_xpath('//xmlns:trk/xmlns:name')&.text || File.basename(@gpx_file_path)
    @activity_type = doc.at_xpath('//xmlns:trk/xmlns:type')&.text&.titleize || 'Other'

    @coordinates = doc.xpath('//xmlns:trkpt').map do |trkpt|
      [trkpt['lon'].to_f, trkpt['lat'].to_f]
    end

    raise 'No track points found in GPX file' if @coordinates.empty?
  end

  # Calculates the bounding box for a set of coordinates
  # @param coordinates [Array<Array<Float>>] The coordinates of the track points
  # @return [Hash] The bounding box with min_lon, max_lon, min_lat, and max_lat
  def calculate_bounding_box(coordinates)
    lons, lats = coordinates.transpose
    min_lon, max_lon = lons.min, lons.max
    min_lat, max_lat = lats.min, lats.max

    # Calculate the minimum size in degrees
    # At the equator, 1 degree is 111.32 km, therefore 1 km is 0.009 degrees.
    # This is used to ensure the map is zoomed out enough to show the surroundings if the track is too short.
    min_size = @min_size * 0.009 # Convert km to degrees

    if (max_lon - min_lon) < min_size
      center_lon = (min_lon + max_lon) / 2
      min_lon = center_lon - (min_size / 2)
      max_lon = center_lon + (min_size / 2)
    end

    if (max_lat - min_lat) < min_size
      center_lat = (min_lat + max_lat) / 2
      min_lat = center_lat - (min_size / 2)
      max_lat = center_lat + (min_size / 2)
    end

    {
      min_lon: min_lon,
      max_lon: max_lon,
      min_lat: min_lat,
      max_lat: max_lat
    }
  end

  # Calculates the aspect ratio of the bounding box
  # @param bounding_box [Hash] The bounding box with min_lon, max_lon, min_lat, and max_lat
  # @return [Float] The aspect ratio
  def calculate_aspect_ratio(bounding_box)
    lon_diff = bounding_box[:max_lon] - bounding_box[:min_lon]
    lat_diff = bounding_box[:max_lat] - bounding_box[:min_lat]
    lon_diff / lat_diff
  end

  # Generates the URL for a static map image from Mapbox
  # @param bounding_box [Hash] The bounding box with min_lon, max_lon, min_lat, and max_lat
  # @param coordinates [Array<Array<Float>>] The coordinates of the track points
  # @param width [Integer] The width of the image
  # @param height [Integer] The height of the image
  # @return [String] The URL for the static map image
  # @see https://docs.mapbox.com/api/maps/static-images/
  def mapbox_image_url(bounding_box, coordinates, width, height)
    start_marker = marker_config(:start_marker, coordinates.first)
    end_marker = marker_config(:end_marker, coordinates.last)

    username, style = MAPBOX_STYLE_URL.split('/')[3..4]
    bbox = "%5B#{bounding_box[:min_lon]},#{bounding_box[:min_lat]},#{bounding_box[:max_lon]},#{bounding_box[:max_lat]}%5D"
    layer = generate_layer

    base_params = {
      padding: @padding,
      access_token: MAPBOX_ACCESS_TOKEN
    }.compact

    url = "https://api.mapbox.com/styles/v1/#{username}/#{style}/static/#{start_marker},#{end_marker}/#{bbox}/#{width}x#{height}@2x?#{base_params.to_query}"
    url += "&addlayer=#{layer.to_json}" if layer.present?
    url += "&before_layer=road-label" if layer.present?
    url
  end

  # Generates the marker configuration for a Mapbox static map image
  # @param marker_type [Symbol] The type of marker (:start_marker or :end_marker)
  # @param coordinate [Array<Float>] The coordinate of the marker
  # @return [String] The marker configuration
  def marker_config(marker_type, coordinate)
    color = marker_type == :start_marker ? START_MARKER_COLOR : END_MARKER_COLOR
    icon = select_icon(marker_type)

    "pin-l-#{icon}+#{color}(#{coordinate[0]},#{coordinate[1]})"
  end

  # Selects the icon for a marker based on the marker type and the GPX file name
  # @param marker_type [Symbol] The type of marker (:start_marker or :end_marker)
  # @return [String] The icon name
  def select_icon(marker_type)
    return ACTIVITY_ICONS[:finish] if marker_type == :end_marker

    return ACTIVITY_ICONS[:swimming] if @activity_type =~ /swimming/i
    return ACTIVITY_ICONS[:cycling]  if @activity_type =~ /cycling|biking/i
    return ACTIVITY_ICONS[:running]  if @activity_type =~ /running/i

    ACTIVITY_ICONS[:start]
  end

  # Downloads an image from a URL and saves it to a file
  # @param image_url [String] The URL of the image to download
  # @param output_file_path [String] The path to save the image
  def download_image(image_url, output_file_path)
    response = HTTParty.get(image_url)

    raise "Failed to download image (HTTP #{response.code}): #{response.body}" unless response.success?

    FileUtils.mkdir_p(File.dirname(output_file_path))
    File.open(output_file_path, 'wb') { |f| f.write(response.body) }
  end

  # Validates the padding value
  # @param padding [String, Integer] The padding value
  # @return [Integer] The padding value
  def validate_padding(padding)
    if padding.is_a?(String) && padding =~ /,/
      padding
    else
      padding.to_i
    end
  end

  # Generates a layer for a Mapbox static map image
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
      "source-layer": "tracks",
      "paint": {
        "line-color": "%23BF0222",
        "line-width": 4,
        "line-opacity": 0.75,
        "line-cap": "round",
        "line-join": "round"
      }
    }
  end
end

