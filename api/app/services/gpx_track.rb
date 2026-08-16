require "nokogiri"
require "digest"
require "time"

# Parses an uploaded GPX file into the handful of values a static map render needs: the track's
# title, its sport, its bounding box, and its two endpoints.
#
# Not an ApplicationService: that base class exists for HTTP integrations, and this makes no
# network calls.
#
# ⚠️ Streams with Nokogiri::XML::Reader rather than building a DOM. Real Garmin exports run to
# several megabytes and ~9,000 trackpoints, and this parse happens in a Puma thread on a 512MB VM
# that has already been OOM-killed once by buffering whole files (see AssetMirror#download). The
# reader keeps peak memory flat and the request inside its 20-second budget.
class GpxTrack
  # Coordinates are rounded before they go anywhere. Garmin writes 26 significant digits per value
  # ("43.52206997573375701904296875"), which triples both the Redis payload and the Mapbox upload
  # for precision no map at this zoom can express — six decimals is roughly 11cm.
  COORDINATE_PRECISION = 6

  # Mapbox caps tileset ids at 32 characters, so the slug is truncated and a digest of the full
  # title appended to keep two long, similarly-named races from collapsing onto one id.
  SLUG_LENGTH = 23
  DIGEST_LENGTH = 8

  # A title that already names its sport doesn't get the activity type appended.
  SPORT_KEYWORDS = /swim|run|bike|biking|cycling|marathon|5k|10k|10-miler|ten-miler|carrera/i

  # Which marker icon a sport suggests. Keys are matched against the GPX's <type>, which Garmin
  # writes as things like "road_biking" and "open_water_swimming". Running is the fallback rather
  # than a neutral placeholder: this is a triathlon blog, and a wrong guess is one dropdown away
  # from right.
  SPORT_ICONS = {
    /swimming/i => "swimming",
    /cycling|biking/i => "bicycle-share",
    /running/i => "pitch"
  }.freeze

  class ParseError < StandardError; end

  attr_reader :activity_type, :activity_start, :coordinates

  # @param io [IO, String] The GPX document, as an IO or a path.
  # @param fallback_name [String, nil] Used as the title when the file names no track.
  # @raise [ParseError] When the document isn't parseable XML or holds no track points.
  def initialize(io, fallback_name: nil)
    @fallback_name = fallback_name
    @coordinates = []
    read(io)

    raise ParseError, "No track points found in GPX file" if @coordinates.empty?

    @activity_name = @activity_name.presence || @fallback_name.presence || "Untitled"
    @activity_type = @activity_type.presence&.titleize || "Other"
  end

  # The activity title, prefixed with its year and suffixed with its sport unless the name already
  # says one.
  # @return [String]
  def title
    year = @activity_start&.strftime("%Y")
    # squish, not strip: a mid-name year would otherwise leave a double space behind.
    title = year.present? ? "#{year} #{@activity_name.gsub(/#{year}/, '').squish}" : @activity_name
    return title if title.match?(SPORT_KEYWORDS)

    "#{title} - #{@activity_type}"
  end

  # A Mapbox-safe tileset id derived from the title: 32 characters max, alphanumerics plus `_`.
  # @return [String]
  def id
    slug = title.parameterize.tr("-", "_").first(SLUG_LENGTH).gsub(/_+$/, "")
    "#{slug}_#{Digest::MD5.hexdigest(title).first(DIGEST_LENGTH)}"
  end

  # The track's extent, with no margins applied — StaticMap adds those at render time, since
  # they're a setting.
  # @return [Hash{Symbol => Float}] :min_lon, :max_lon, :min_lat, :max_lat.
  def bounds
    lons, lats = @coordinates.transpose

    { min_lon: lons.min, max_lon: lons.max, min_lat: lats.min, max_lat: lats.max }
  end

  # @return [Array<Float>] The first track point, as [lon, lat].
  def start_coord = @coordinates.first

  # @return [Array<Float>] The last track point, as [lon, lat].
  def end_coord = @coordinates.last

  # The icon this track's sport suggests, used to seed the start marker's setting.
  # @return [String]
  def start_icon
    SPORT_ICONS.find { |pattern, _icon| @activity_type.match?(pattern) }&.last || "pitch"
  end

  private

  # Walks the document once, picking up the track's name, type, start time, and points.
  #
  # The name and type are matched as direct children of <trk> by depth, so a <metadata><name> or a
  # waypoint's own <name> can't be mistaken for the track's.
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

  # @return [Boolean] Whether this is the first point, and so the one whose <time> to read.
  def record_point(node)
    lat = node.attribute("lat")
    lon = node.attribute("lon")
    return false if lat.blank? || lon.blank?

    @coordinates << [ lon.to_f.round(COORDINATE_PRECISION), lat.to_f.round(COORDINATE_PRECISION) ]
    @coordinates.length == 1 && !node.self_closing?
  end

  def assign(field, value)
    case field
    when :name then @activity_name = value.to_s.strip
    when :type then @activity_type = value.to_s.strip
    when :time then @activity_start = parse_time(value)
    end
  end

  # A missing or unparseable timestamp just means the title carries no year.
  # @return [Time, nil]
  def parse_time(value)
    Time.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
