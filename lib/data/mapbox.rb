require 'httparty'
require 'nokogiri'
require 'fileutils'

class Mapbox
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

  def initialize(
    gpx_file_path,
    max_height: 1280,
    min_size_km: 0,
    padding: 40
  )
    @gpx_file_path = gpx_file_path
    @max_height = [max_height, MAX_HEIGHT].min
    @min_size_km = min_size_km
    @padding = padding
  end

  # Generates a static map image from a GPX file, and saves it to the data/mapbox/images folder.
  # and then uses the Mapbox Static API to generate a static map image, but it doesn't add the GPX file to the map.
  # Before running this task, the GPX file must be uploaded to Mapbox and added to the map in Mapbox Studio first.
  def generate_map_image
    puts "Generating map for #{File.basename(@gpx_file_path)}"
    coordinates = extract_coordinates_from_gpx(@gpx_file_path)
    bounding_box = calculate_bounding_box(coordinates)

    image_file_name = File.basename(@gpx_file_path, '.gpx') + '.png'
    output_file_path = File.join(IMAGES_FOLDER, image_file_name)

    aspect_ratio = calculate_aspect_ratio(bounding_box)
    height = (WIDTH / aspect_ratio).clamp(MIN_HEIGHT, @max_height).round

    image_url = mapbox_image_url(bounding_box, coordinates, WIDTH, height)
    puts "  Downloading image: #{image_url}"
    download_image(image_url, output_file_path)
    puts "  ✅ Image saved to #{image_file_name}\n\n"
  end

  private

  # Extracts the coordinates from a GPX file
  # @param gpx_file_path [String] The path to the GPX file
  # @return [Array<Array<Float>>] The coordinates of the track points
  def extract_coordinates_from_gpx(gpx_file_path)
    file = File.open(gpx_file_path)
    doc = Nokogiri::XML(file)
    file.close

    coordinates = doc.xpath('//xmlns:trkpt').map do |trkpt|
      [trkpt['lon'].to_f, trkpt['lat'].to_f]
    end

    raise 'No track points found in GPX file' if coordinates.empty?

    coordinates
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
    min_size = @min_size_km * 0.009 # Convert km to degrees

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

    "https://api.mapbox.com/styles/v1/#{username}/#{style}/static/#{start_marker},#{end_marker}/#{bbox}/#{width}x#{height}@2x?padding=#{@padding}&access_token=#{MAPBOX_ACCESS_TOKEN}"
  end

  # Generates the marker configuration for a Mapbox static map image
  # @param marker_type [Symbol] The type of marker (:start_marker or :end_marker)
  # @param coordinate [Array<Float>] The coordinate of the marker
  # @return [String] The marker configuration
  def marker_config(marker_type, coordinate)
    color = marker_type == :start_marker ? START_MARKER_COLOR : END_MARKER_COLOR
    icon = select_icon(marker_type)

    "pin-s-#{icon}+#{color}(#{coordinate[0]},#{coordinate[1]})"
  end

  # Selects the icon for a marker based on the marker type and the GPX file name
  # @param marker_type [Symbol] The type of marker (:start_marker or :end_marker)
  # @return [String] The icon name
  def select_icon(marker_type)
    return ACTIVITY_ICONS[:finish] if marker_type == :end_marker
    return ACTIVITY_ICONS[:start] if marker_type == :start_marker

    filename = File.basename(@gpx_file_path).downcase
    return ACTIVITY_ICONS[:swimming] if filename.include?('swim')
    return ACTIVITY_ICONS[:cycling] if filename.include?('bike') || filename.include?('cycling')
    return ACTIVITY_ICONS[:running] if filename.include?('run') || filename.include?('marathon') || filename.include?('5k') || filename.include?('10k') || filename.include?('12k')

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
end
