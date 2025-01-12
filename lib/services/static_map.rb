require 'httparty'
require 'nokogiri'
require 'fileutils'
require 'active_support/all'

class StaticMap
  attr_accessor :tileset_id

  GPX_FOLDER = File.expand_path('../../../data/maps/gpx', __FILE__)
  IMAGES_FOLDER = File.expand_path('../../../data/maps/images', __FILE__)

  MAPBOX_ACCESS_TOKEN = ENV['MAPBOX_ACCESS_TOKEN'] || raise('Mapbox access token is missing!')
  MAPBOX_STYLE_URL = ENV['MAPBOX_STYLE_URL'] || raise('Map style URL is missing!')

  ACTIVITY_ICONS = {
    running: 'pitch',
    cycling: 'bicycle-share',
    swimming: 'swimming',
    start: 'rocket',
    finish: 'racetrack'
  }

  START_MARKER_COLOR = '18A644' # Green
  END_MARKER_COLOR = 'F90F1A' # Red

  WIDTH = 1280
  MAX_HEIGHT = 1280
  MIN_HEIGHT = 800
  PADDING = 50
  MIN_SIZE = 1

  def initialize(gpx_file_path, options = {})
    options.reverse_merge!(
      max_height: MAX_HEIGHT,
      min_size: MIN_SIZE
    )

    @tileset_id = options[:tileset_id]
    @min_size = options[:min_size].to_f
    @padding = validate_padding(options[:padding])
    extract_data_from_gpx(gpx_file_path)
    @bounding_box = calculate_bounding_box(@coordinates)
    @bounding_box_aspect_ratio = bounding_box_aspect_ratio(@bounding_box)
    @width = WIDTH
    @height = (@width / @bounding_box_aspect_ratio).clamp(MIN_HEIGHT, [options[:max_height].to_i, MAX_HEIGHT].min).round
  end

  # Generates a map as a static image and saves it to the data/mapbox/images folder.
  # It uses the Mapbox Static API to generate the map image based on the bounding box of the GPX file, but it doesn't add the GPX file itself to the map.
  # Before running this task, the GPX file must be uploaded to Mapbox as a tileset.
  def generate_map_image
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
    return @activity_name if @activity_name =~ /swim|run|bike|biking|cycling|marathon|10k|5k|12k/i
    "#{@activity_name} - #{@activity_type}"
  end

  private

  # Returns the file name for the map image based on the activity name and date.
  # @return [String] The file name for the map image
  def image_file_name
    base = "#{@activity_start&.strftime('%Y-%m-%d')} #{activity_title}".strip
    base.parameterize + '.png'
  end

  # Extracts data from a GPX file and saves it in instance variables.
  # @param gpx_file_path [String] The path to the GPX file
  def extract_data_from_gpx(gpx_file_path)
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

    # Convert the center latitude to radians for trigonometric calculations
    # We use radians because trigonometric functions in Ruby (like Math.cos) expect radians.
    center_lat_in_radians = center_lat * Math::PI / 180

    # The cosine of the latitude adjusts the length of one degree of longitude.
    # At the equator (latitude 0°), cos(0) = 1, so 1° of longitude is approximately 111.32 km.
    # As you move toward the poles, cos(latitude) decreases, making longitude degrees shorter.
    cos_lat = Math.cos(center_lat_in_radians)

    # Calculate the minimum size of the bounding box in degrees of latitude.
    # 1° of latitude ≈ 111.32 km everywhere on Earth.
    min_size_lat = @min_size / 111.32

    # Calculate the minimum size of the bounding box in degrees of longitude at the given latitude.
    # 1° of longitude ≈ 111.32 km * cos(latitude).
    min_size_lon = @min_size / (111.32 * cos_lat)

    # Ensure the longitude span is at least the minimum size
    if (max_lon - min_lon) < min_size_lon
      # Calculate the center of the current longitude span
      center_lon = (min_lon + max_lon) / 2

      # Adjust the min and max longitude so the total span is equal to min_size_lon
      min_lon = center_lon - (min_size_lon / 2)
      max_lon = center_lon + (min_size_lon / 2)
    end

    # Ensure the latitude span is at least the minimum size
    if (max_lat - min_lat) < min_size_lat
      # Calculate the center of the current latitude span
      center_lat = (min_lat + max_lat) / 2

      # Adjust the min and max latitude so the total span is equal to min_size_lat
      min_lat = center_lat - (min_size_lat / 2)
      max_lat = center_lat + (min_size_lat / 2)
    end

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
    cos_lat = Math.cos(center_lat * Math::PI / 180) # Cosine of latitude for longitude adjustment

    # Convert the differences in longitude and latitude to kilometers
    width_km = (bounding_box[:max_lon] - bounding_box[:min_lon]) * 111.32 * cos_lat
    height_km = (bounding_box[:max_lat] - bounding_box[:min_lat]) * 111.32

    # Calculate the aspect ratio as width in km divided by height in km
    width_km / height_km
  end

  # Generates the URL for a static map image from Mapbox.
  # @return [String] The URL for the static map image
  # @see https://docs.mapbox.com/api/maps/static-images/
  def mapbox_image_url
    start_marker = marker_config(:start_marker, @coordinates.first)
    end_marker = marker_config(:end_marker, @coordinates.last)

    username, style = MAPBOX_STYLE_URL.split('/')[3..4]
    bbox = "%5B#{@bounding_box[:min_lon]},#{@bounding_box[:min_lat]},#{@bounding_box[:max_lon]},#{@bounding_box[:max_lat]}%5D"
    layer = generate_layer

    base_params = {
      padding: @padding,
      access_token: MAPBOX_ACCESS_TOKEN
    }.compact

    url = "https://api.mapbox.com/styles/v1/#{username}/#{style}/static/#{end_marker},#{start_marker}/#{bbox}/#{@width}x#{@height}@2x?#{base_params.to_query}"
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
    return ACTIVITY_ICONS[:finish] if marker_type == :end_marker

    return ACTIVITY_ICONS[:swimming] if @activity_type =~ /swimming/i
    return ACTIVITY_ICONS[:cycling]  if @activity_type =~ /cycling|biking/i
    return ACTIVITY_ICONS[:running]  if @activity_type =~ /running/i

    ACTIVITY_ICONS[:start]
  end

  # Downloads an image from a URL and saves it to a file.
  # @param image_url [String] The URL of the image to download
  # @param output_file_path [String] The path to save the image
  def download_image(image_url, output_file_path)
    response = HTTParty.get(image_url)

    raise "Failed to download image (HTTP #{response.code}): #{response.body}" unless response.success?

    FileUtils.mkdir_p(File.dirname(output_file_path))
    File.open(output_file_path, 'wb') { |f| f.write(response.body) }
  end

  # Validates the padding value.
  # @param padding [String, Integer] The padding value
  # @return [Integer] The padding value
  def validate_padding(padding)
    # Convert input to string and split by commas, taking only first 4 values
    values = padding.to_s.split(',').map(&:to_i).first(4)

    case values.length
    when 1  # Single value: apply to all sides
      values[0]
    when 2  # Two values: top/bottom, left/right
      "#{values[0]},#{values[1]},#{values[0]},#{values[1]}"
    when 3  # Three values: top, left/right, bottom
      "#{values[0]},#{values[1]},#{values[2]},#{values[1]}"
    when 4  # Four values: top, right, bottom, left
      values.join(',')
    else
      PADDING  # Default padding if empty input
    end
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

