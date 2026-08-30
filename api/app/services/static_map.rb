require "json"
require "uri"

# Renders one track as a static map image.
#
# This code draws nothing. The Static Images API draws the track (an `addlayer` over the vector
# tileset of the track) and the two pins on the server, and it returns a complete PNG. Thus this
# code only makes a URL and gets the bytes.
#
# It is not an ApplicationService, because the response is an image and not cacheable JSON.
# @see https://docs.mapbox.com/api/maps/static-images/
class StaticMap
  DEFAULT_STYLE_URL = "mapbox://styles/mapbox/outdoors-v12".freeze

  # A style URL comes to this class from a form field and goes into a URL that the server gets.
  # Thus the code matches it against the Mapbox shape and does not use it as it is.
  STYLE_URL_FORMAT = %r{\Amapbox://styles/[\w-]+/[\w-]+\z}

  # The Mapbox styles, in a dropdown. A custom style is a text field, and it replaces the style
  # that the user selects here.
  # @see https://docs.mapbox.com/api/maps/styles/#mapbox-styles
  # ⚠️ The value is the name of a translation and NOT the words on the screen. Each user-facing
  # word of the admin is in config/locales/en.yml. Use `.style_options` to render the dropdown.
  STYLE_PRESETS = {
    "mapbox://styles/mapbox/outdoors-v12" => "outdoors",
    "mapbox://styles/mapbox/streets-v12" => "streets",
    "mapbox://styles/mapbox/light-v11" => "light",
    "mapbox://styles/mapbox/dark-v11" => "dark",
    "mapbox://styles/mapbox/satellite-v9" => "satellite",
    "mapbox://styles/mapbox/satellite-streets-v12" => "satellite_streets",
    "mapbox://styles/mapbox/navigation-day-v1" => "navigation_day",
    "mapbox://styles/mapbox/navigation-night-v1" => "navigation_night"
  }.freeze

  # The marker icons that are available. The name says what each icon marks, and it is not the
  # Maki id.
  # @see https://labs.mapbox.com/maki-icons/
  # ⚠️ The value is the name of a translation and NOT the words on the screen. Use `.icon_options`
  # to render the dropdown.
  MARKER_ICONS = {
    "pitch" => "running",
    "bicycle-share" => "cycling",
    "swimming" => "swimming",
    "racetrack" => "finish",
    "danger" => "dnf"
  }.freeze

  # @return [Hash{String=>String}] Each style URL, and the name of that style on the screen.
  def self.style_options
    STYLE_PRESETS.transform_values { |name| I18n.t("admin.course_maps.styles.#{name}") }
  end

  # @return [Hash{String=>String}] Each Maki icon id, and what that icon marks on the screen.
  def self.icon_options
    MARKER_ICONS.transform_values { |name| I18n.t("admin.course_maps.icons.#{name}") }
  end

  # The padding and the extra map apply to each side, in the Mapbox order.
  SIDES = %w[top right bottom left].freeze

  # The maximum values for each side, thus an incorrect keystroke cannot ask Mapbox for a very
  # large image.
  MAX_PADDING = 500
  MAX_MARGIN_KM = 500

  # The image always has this width before the @2x of Mapbox makes it two times larger. The aspect
  # ratio of the track gives the height, if the settings do not set one. Both have a maximum.
  WIDTH = 1280
  MIN_HEIGHT = 800
  MAX_HEIGHT = 1280

  # The approximate length of one degree of latitude in kilometers. One degree of longitude is
  # this value multiplied by the cosine of the latitude.
  KM_PER_DEGREE = 111.32

  HTTP_TIMEOUT = 30
  HTTP_MAX_ATTEMPTS = 3

  # All the settings, with the value that the Rake task contained. The sport of each track gives
  # its `start_icon`. Refer to .defaults_for.
  DEFAULTS = {
    "padding_top" => 50,
    "padding_right" => 50,
    "padding_bottom" => 50,
    "padding_left" => 50,
    "margin_top" => 0,
    "margin_right" => 0,
    "margin_bottom" => 0,
    "margin_left" => 0,
    "height" => "",
    "finish_on_top" => false,
    "track_color" => "#bf0222",
    "track_width" => 4,
    "track_opacity" => 0.75,
    "start_icon" => "pitch",
    "start_color" => "#18a644",
    "end_icon" => "racetrack",
    "end_color" => "#f90f1a",
    "style_preset" => DEFAULT_STYLE_URL,
    "style_url" => ""
  }.freeze

  class RenderError < StandardError; end

  # The settings for a new track: the defaults, with the start marker from the sport in the GPX
  # and the style from the environment.
  #
  # MAPBOX_STYLE_URL goes into the field that can hold it: the dropdown if it names a Mapbox style,
  # or the custom field. Thus a style from the configuration appears where you can edit it, and
  # not as a preset that the form does not select.
  #
  # @param start_icon [String] The icon from GpxTrack#start_icon.
  # @return [Hash]
  def self.defaults_for(start_icon)
    configured = ENV["MAPBOX_STYLE_URL"].to_s
    preset = STYLE_PRESETS.key?(configured)

    DEFAULTS.merge(
      "start_icon" => start_icon.presence || DEFAULTS["start_icon"],
      "style_preset" => preset ? configured : DEFAULT_STYLE_URL,
      "style_url" => !preset && configured.match?(STYLE_URL_FORMAT) ? configured : ""
    )
  end

  # @param track [Hash] A TrackLibrary record: "tileset_id", "source_layer", "bounds",
  #   "start_coord", "end_coord", "title".
  # @param settings [Hash] The render settings, which go on top of DEFAULTS.
  def initialize(track:, settings: {})
    @track = track
    @settings = self.class.defaults_for(nil).merge(settings.to_h.compact)
  end

  # @return [String] The Mapbox Static Images API URL, with the access token.
  def url
    # ⚠️ Mapbox draws the overlays in order, thus the LAST one is on top. The default puts the
    # start on top, because a finish pin over the start of an out-and-back course hides the
    # start.
    markers = truthy?(@settings["finish_on_top"]) ? [ marker(:start), marker(:end) ] : [ marker(:end), marker(:start) ]

    box = bounds
    bbox = "%5B#{box[:min_lon]},#{box[:min_lat]},#{box[:max_lon]},#{box[:max_lat]}%5D"
    query = { padding: padding.join(","), access_token: render_token }.to_query

    # Always @2x. The API bills for each request and not for each pixel, thus a smaller preview
    # saves nothing, and the zoom dialog shows the preview at the full width.
    url = "https://api.mapbox.com/styles/v1/#{style_path}/static/#{markers.join(',')}/#{bbox}/#{WIDTH}x#{height}@2x?#{query}"
    url += "&addlayer=#{layer.to_json}&before_layer=road-label" if layer.present?
    url
  end

  # Gets the rendered PNG.
  # @return [String] The image bytes.
  # @raise [RenderError] If Mapbox refuses the request or continues to fail.
  def render
    response = get_with_retries(url)
    raise RenderError, error_message_from(response) unless response.success?

    response.body
  end

  # @return [String] The download file name, which comes from the title of the track.
  def filename
    "#{@track['title'].to_s.parameterize.presence || 'map'}.png"
  end

  private

  # The Mapbox token. The code finds it only when it is necessary, thus a new instance of this
  # class needs no token. It uses the secret token first, because that is the only token that can
  # read the private tilesets that MTS makes.
  # @return [String]
  def render_token
    ENV["MAPBOX_SECRET_TOKEN"].presence ||
      ENV["MAPBOX_ACCESS_TOKEN"].presence ||
      raise(RenderError, "Mapbox access token is missing!")
  end

  # The custom style replaces the dropdown style, and the default applies if both are incorrect.
  # @return [String] "username/style" from the style URL that the user selects.
  def style_path
    style = [ @settings["style_url"], @settings["style_preset"], DEFAULT_STYLE_URL ]
      .find { |candidate| candidate.to_s.match?(STYLE_URL_FORMAT) }

    style.split("/")[3..4].join("/")
  end

  # The area of the track, with the margin of each side added. A latitude changes directly into
  # degrees. A longitude becomes shorter near the poles, by the cosine of the latitude.
  # @return [Hash{Symbol => Float}]
  def bounds
    raw = @track["bounds"] || {}
    min_lon, max_lon = raw["min_lon"].to_f, raw["max_lon"].to_f
    min_lat, max_lat = raw["min_lat"].to_f, raw["max_lat"].to_f

    top, right, bottom, left = margins
    cos = cos_lat((min_lat + max_lat) / 2)

    {
      min_lon: min_lon - (left / (KM_PER_DEGREE * cos)),
      max_lon: max_lon + (right / (KM_PER_DEGREE * cos)),
      min_lat: min_lat - (bottom / KM_PER_DEGREE),
      max_lat: max_lat + (top / KM_PER_DEGREE)
    }
  end

  # @return [Array<Integer>] The padding for each side, in the Mapbox order.
  def padding
    SIDES.map { |side| @settings["padding_#{side}"].to_i.clamp(0, MAX_PADDING) }
  end

  # @return [Array<Float>] The extra kilometers of map for each side, in the Mapbox order.
  def margins
    SIDES.map { |side| @settings["margin_#{side}"].to_f.clamp(0, MAX_MARGIN_KM) }
  end

  # The code uses a height from the settings only when it is more than the vertical padding. If it
  # is not, there is no space to draw in, thus the code uses the aspect ratio of the track.
  # @return [Integer]
  def height
    top, _right, bottom, _left = padding
    requested = @settings["height"].to_i

    return requested.clamp(MIN_HEIGHT, MAX_HEIGHT) if requested > top + bottom

    (WIDTH / aspect_ratio).ceil.clamp(MIN_HEIGHT, MAX_HEIGHT)
  end

  # @return [Float] The width in km divided by the height in km. It checks for a span of zero.
  def aspect_ratio
    box = bounds
    center_lat = (box[:min_lat] + box[:max_lat]) / 2

    width_km = (box[:max_lon] - box[:min_lon]) * KM_PER_DEGREE * cos_lat(center_lat)
    height_km = (box[:max_lat] - box[:min_lat]) * KM_PER_DEGREE

    ratio = width_km / height_km
    ratio.finite? && ratio.positive? ? ratio : 1.0
  end

  def cos_lat(latitude)
    Math.cos(latitude * Math::PI / 180)
  end

  # @param which [Symbol] :start or :end.
  # @return [String] A Mapbox pin overlay, for example "pin-l-rocket+18a644(-116.05,43.52)".
  def marker(which)
    coordinate = @track[which == :start ? "start_coord" : "end_coord"].to_a
    icon = @settings["#{which}_icon"].to_s.gsub(/[^a-z0-9-]/i, "")
    color = hex(@settings["#{which}_color"])

    "pin-l-#{icon}+#{color}(#{coordinate[0]},#{coordinate[1]})"
  end

  # The track, from its vector tileset, below the road labels.
  # @return [Hash, nil] Nil if the tileset is not published.
  def layer
    tileset_id = @track["tileset_id"]
    return if tileset_id.blank?

    {
      "id": tileset_id,
      "type": "line",
      "source": { "type": "vector", "url": "mapbox://#{tileset_id}" },
      "source-layer": @track["source_layer"].presence || MapboxTileset::LAYER_NAME,
      "paint": {
        "line-color": URI.encode_www_form_component("##{hex(@settings['track_color'])}"),
        "line-width": @settings["track_width"].to_f,
        "line-opacity": @settings["track_opacity"].to_f.clamp(0.0, 1.0),
        "line-cap": "round",
        "line-join": "round"
      }
    }
  end

  # @return [String] Six lowercase hex digits. It removes a "#" at the start and each incorrect
  #   character.
  def hex(color)
    digits = color.to_s.delete("#").gsub(/[^0-9a-f]/i, "").downcase.first(6)
    digits.length == 6 ? digits : "000000"
  end

  # A checkbox and a JSON value both come here, thus "0" and "false" must mean false.
  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value) || false
  end

  # Does the request again after a temporary failure (a network error or a 5xx), a maximum number
  # of times.
  def get_with_retries(url)
    attempt = 0
    begin
      attempt += 1
      response = HTTParty.get(url, timeout: HTTP_TIMEOUT)
      return response if response.success? || response.code < 500

      raise RenderError, "Mapbox returned status #{response.code}"
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, HTTParty::Error, RenderError => e
      raise e if attempt >= HTTP_MAX_ATTEMPTS

      sleep(attempt)
      retry
    end
  end

  # Makes a clear error from a failed response. If it cannot, it uses the status code.
  def error_message_from(response)
    message = begin
      JSON.parse(response.body, symbolize_names: true)[:message]
    rescue JSON::ParserError, TypeError
      nil
    end
    message.presence || "Mapbox request failed with status #{response.code}"
  end
end
