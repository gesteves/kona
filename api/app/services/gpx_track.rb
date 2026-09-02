require "nokogiri"
require "digest"
require "time"

# Parses a GPX file that a user uploads, and gives the few values that a static map render needs:
# the title of the track, its sport, its bounding box, and its two end points.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call.
#
# ⚠️ It uses Nokogiri::XML::Reader on a stream and does not make a DOM. A true Garmin export is
# several megabytes and has approximately 9,000 track points. This parse occurs in a Puma thread on
# a 512MB VM, and an OOM kill already stopped that VM one time because the code held full files in
# memory (refer to AssetMirror#download). The reader keeps the peak memory low and the request in
# its 20-second budget.
class GpxTrack
  # The code rounds each coordinate first. Garmin writes 26 significant digits for each value
  # ("43.52206997573375701904296875"). That makes the Redis payload and the Mapbox upload three
  # times larger, for an accuracy that no map at this zoom can show. Six decimals is approximately
  # 11cm.
  COORDINATE_PRECISION = 6

  # Mapbox permits a maximum of 32 characters in a tileset id. Thus the code cuts the slug and adds
  # a digest of the full title. That keeps two long races with similar names on two different
  # ids.
  SLUG_LENGTH = 23
  DIGEST_LENGTH = 8

  # The most track points. A Garmin export of a long race has approximately 9,000, and each point
  # goes into Redis and to Mapbox. A file far past this is not a race track.
  MAX_POINTS = 100_000

  # The code does not add the activity type to a title that already names its sport.
  SPORT_KEYWORDS = /swim|run|bike|biking|cycling|marathon|5k|10k|10-miler|ten-miler|carrera/i

  # The marker icon for each sport. The code matches each key against the <type> in the GPX, which
  # Garmin writes as text such as "road_biking" and "open_water_swimming". The default is running
  # and not a neutral icon: this is a triathlon blog, and one dropdown corrects a wrong icon.
  SPORT_ICONS = {
    /swimming/i => "swimming",
    /cycling|biking/i => "bicycle-share",
    /running/i => "pitch"
  }.freeze

  class ParseError < StandardError; end

  attr_reader :activity_type, :activity_start, :coordinates

  # @param io [IO, String] The GPX document, as an IO or as a path.
  # @param fallback_name [String, nil] The title to use when the file names no track.
  # @raise [ParseError] If the code cannot parse the document as XML, or if it has no track
  #   points.
  def initialize(io, fallback_name: nil)
    @fallback_name = fallback_name
    @coordinates = []
    read(io)

    raise ParseError, "No track points found in GPX file" if @coordinates.empty?

    @activity_name = @activity_name.presence || @fallback_name.presence || "Untitled"
    @activity_type = @activity_type.presence&.titleize || "Other"
  end

  # The title of the activity, with its year at the start and its sport at the end. It does not add
  # the sport if the name already names one.
  # @return [String]
  def title
    year = @activity_start&.strftime("%Y")
    # Use squish, not strip. A year in the middle of a name would leave two spaces.
    title = year.present? ? "#{year} #{@activity_name.gsub(/#{year}/, '').squish}" : @activity_name
    return title if title.match?(SPORT_KEYWORDS)

    "#{title} - #{@activity_type}"
  end

  # A tileset id for Mapbox, from the title: 32 characters maximum, with letters, digits, and `_`.
  # @return [String]
  def id
    slug = title.parameterize.tr("-", "_").first(SLUG_LENGTH).gsub(/_+$/, "")
    "#{slug}_#{Digest::MD5.hexdigest(title).first(DIGEST_LENGTH)}"
  end

  # The area of the track, with no margins. StaticMap adds the margins at render time, because
  # they are a setting.
  # @return [Hash{Symbol => Float}] :min_lon, :max_lon, :min_lat, :max_lat.
  def bounds
    lons, lats = @coordinates.transpose

    { min_lon: lons.min, max_lon: lons.max, min_lat: lats.min, max_lat: lats.max }
  end

  # @return [Array<Float>] The first track point, as [lon, lat].
  def start_coord = @coordinates.first

  # @return [Array<Float>] The last track point, as [lon, lat].
  def end_coord = @coordinates.last

  # The icon for the sport of this track. It gives the first value of the start-marker setting.
  # @return [String]
  def start_icon
    SPORT_ICONS.find { |pattern, _icon| @activity_type.match?(pattern) }&.last || "pitch"
  end

  private

  # Reads the document one time and gets the name, the type, the start time, and the points of the
  # track.
  #
  # The code matches the name and the type as direct children of <trk>, by depth. Thus it cannot
  # read a <metadata><name>, or the <name> of a waypoint, as the name of the track.
  def read(io)
    reader = Nokogiri::XML::Reader(io)
    trk_depth = nil
    in_first_point = false
    capturing = nil

    reader.each do |node|
      case node.node_type
      when Nokogiri::XML::Reader::TYPE_ELEMENT
        capturing = nil

        case node.name
        when "trk"
          trk_depth ||= node.depth
        when "name"
          capturing = :name if @activity_name.nil? && trk_depth && node.depth == trk_depth + 1
        when "type"
          capturing = :type if @activity_type.nil? && trk_depth && node.depth == trk_depth + 1
        when "trkpt"
          in_first_point = record_point(node)
        when "time"
          capturing = :time if in_first_point && @activity_start.nil?
        end
      when Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_CDATA
        assign(capturing, node.value)
        capturing = nil
      when Nokogiri::XML::Reader::TYPE_END_ELEMENT
        in_first_point = false if node.name == "trkpt"
      end
    end
  rescue Nokogiri::XML::SyntaxError => e
    raise ParseError, "Could not parse the GPX file: #{e.message}"
  end

  # @return [Boolean] True if this is the first point, whose <time> the code reads.
  def record_point(node)
    lat = node.attribute("lat")
    lon = node.attribute("lon")
    return false if lat.blank? || lon.blank?

    @coordinates << [ lon.to_f.round(COORDINATE_PRECISION), lat.to_f.round(COORDINATE_PRECISION) ]
    raise ParseError, "The GPX file has more than #{MAX_POINTS} track points" if @coordinates.length > MAX_POINTS

    @coordinates.length == 1 && !node.self_closing?
  end

  def assign(field, value)
    case field
    when :name then @activity_name = value.to_s.strip
    when :type then @activity_type = value.to_s.strip
    when :time then @activity_start = parse_time(value)
    end
  end

  # A timestamp that is absent, or that the code cannot parse, means that the title has no year.
  # @return [Time, nil]
  def parse_time(value)
    Time.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
