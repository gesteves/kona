require "json"
require "uri"

# Renders one track as a static map image.
#
# Nothing is composited locally: the Static Images API draws the track (an `addlayer` over the
# track's vector tileset) and both pins server-side and returns a finished PNG, so this only ever
# builds a URL and fetches bytes.
#
# Not an ApplicationService: the response is an image, not cacheable JSON.
# @see https://docs.mapbox.com/api/maps/static-images/
class StaticMap
  DEFAULT_STYLE_URL = "mapbox://styles/mapbox/outdoors-v12".freeze

  # A style URL reaches this class from a form field and ends up in a URL the server fetches, so
  # it's matched against Mapbox's own shape rather than interpolated as given.
  STYLE_URL_FORMAT = %r{\Amapbox://styles/[\w-]+/[\w-]+\z}

  # Mapbox's own styles, offered as a dropdown. A custom style is a free-text field that wins over
  # whichever of these is picked.
  # @see https://docs.mapbox.com/api/maps/styles/#mapbox-styles
  STYLE_PRESETS = {
    "mapbox://styles/mapbox/outdoors-v12" => "Outdoors",
    "mapbox://styles/mapbox/streets-v12" => "Streets",
    "mapbox://styles/mapbox/light-v11" => "Light",
    "mapbox://styles/mapbox/dark-v11" => "Dark",
    "mapbox://styles/mapbox/satellite-v9" => "Satellite",
    "mapbox://styles/mapbox/satellite-streets-v12" => "Satellite streets",
    "mapbox://styles/mapbox/navigation-day-v1" => "Navigation, day",
    "mapbox://styles/mapbox/navigation-night-v1" => "Navigation, night"
  }.freeze

  # The marker icons on offer, named for what they mark rather than by their Maki id.
  # @see https://labs.mapbox.com/maki-icons/
  MARKER_ICONS = {
    "pitch" => "Running",
    "bicycle-share" => "Cycling",
    "swimming" => "Swimming",
    "racetrack" => "Finish",
    "danger" => "DNF"
  }.freeze

  # Padding and extra map are per-side, in Mapbox's order.
  SIDES = %w[top right bottom left].freeze

  # Ceilings for the per-side values, so a stray keystroke can't ask Mapbox for something absurd.
  MAX_PADDING = 500
  MAX_MARGIN_KM = 500

  # The image is always this wide; height is derived from the track's aspect ratio unless one is
  # set, and clamped either way.
  WIDTH = 1280
  MIN_HEIGHT = 800
  MAX_HEIGHT = 1280

  # Approximate length of one degree of latitude in kilometers. One degree of longitude is this
  # value scaled by the cosine of the latitude.
  KM_PER_DEGREE = 111.32

  HTTP_TIMEOUT = 30
  HTTP_MAX_ATTEMPTS = 3

  # Every knob, with the value the Rake task used to hardcode. `start_icon` is overridden per
  # track from its sport — see .defaults_for.
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

  # The settings a freshly uploaded track starts with: the defaults, with the start marker seeded
  # from the sport the GPX declared and the style from the environment.
  #
  # MAPBOX_STYLE_URL seeds whichever field can hold it — the dropdown if it names one of Mapbox\'s
  # own styles, the custom field otherwise — so a configured style shows up where it\'s editable
  # rather than as a preset that silently isn\'t selected.
  #
  # @param start_icon [String] The icon GpxTrack#start_icon suggested.
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
  # @param settings [Hash] Render settings, merged over DEFAULTS.
  # @param scale [Integer] 1 or 2 (Mapbox's `@2x`). Previews render at 1, downloads at 2.
  def initialize(track:, settings: {}, scale: 2)
    @track = track
    @settings = self.class.defaults_for(nil).merge(settings.to_h.compact)
    @scale = scale == 2 ? 2 : 1
  end

  # @return [String] The Mapbox Static Images API URL, access token included.
  def url
    # ⚠️ Mapbox draws overlays in order, so the LAST one listed ends up on top. Start-on-top is the
    # default because a finish pin dropped over the start of an out-and-back hides where you began.
    markers = truthy?(@settings["finish_on_top"]) ? [ marker(:start), marker(:end) ] : [ marker(:end), marker(:start) ]

    box = bounds
    bbox = "%5B#{box[:min_lon]},#{box[:min_lat]},#{box[:max_lon]},#{box[:max_lat]}%5D"
    suffix = @scale == 2 ? "@2x" : ""
    query = { padding: padding.join(","), access_token: render_token }.to_query

    url = "https://api.mapbox.com/styles/v1/#{style_path}/static/#{markers.join(',')}/#{bbox}/#{WIDTH}x#{height}#{suffix}?#{query}"
    url += "&addlayer=#{layer.to_json}&before_layer=road-label" if layer.present?
    url
  end

  # Fetches the rendered PNG.
  # @return [String] The image bytes.
  # @raise [RenderError] When Mapbox refuses or keeps failing.
  def render
    response = get_with_retries(url)
    raise RenderError, error_message_from(response) unless response.success?

    response.body
  end

  # @return [String] The download filename, derived from the track's title.
  def filename
    "#{@track['title'].to_s.parameterize.presence || 'map'}.png"
  end

  private

  # The Mapbox token, resolved lazily so merely constructing this class never demands one. Prefers
  # the secret token, which is the only one that can read the private tilesets MTS creates.
  # @return [String]
  def render_token
    ENV["MAPBOX_SECRET_TOKEN"].presence ||
      ENV["MAPBOX_ACCESS_TOKEN"].presence ||
      raise(RenderError, "Mapbox access token is missing!")
  end

  # The custom style wins over the dropdown, and the default catches both being unusable.
  # @return [String] "username/style" from the chosen style URL.
  def style_path
    style = [ @settings["style_url"], @settings["style_preset"], DEFAULT_STYLE_URL ]
      .find { |candidate| candidate.to_s.match?(STYLE_URL_FORMAT) }

    style.split("/")[3..4].join("/")
  end

  # The track's extent, expanded by the per-side margins. Latitudes convert straight to degrees;
  # longitudes shorten toward the poles by the cosine of the latitude.
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

  # @return [Array<Integer>] Padding per side, in Mapbox's order.
  def padding
    SIDES.map { |side| @settings["padding_#{side}"].to_i.clamp(0, MAX_PADDING) }
  end

  # @return [Array<Float>] Extra kilometers of map per side, in Mapbox's order.
  def margins
    SIDES.map { |side| @settings["margin_#{side}"].to_f.clamp(0, MAX_MARGIN_KM) }
  end

  # A supplied height is only honored when it clears the vertical padding — otherwise there'd be
  # no room left to draw in, so fall back to the track's own aspect ratio.
  # @return [Integer]
  def height
    top, _right, bottom, _left = padding
    requested = @settings["height"].to_i

    return requested.clamp(MIN_HEIGHT, MAX_HEIGHT) if requested > top + bottom

    (WIDTH / aspect_ratio).ceil.clamp(MIN_HEIGHT, MAX_HEIGHT)
  end

  # @return [Float] Width in km over height in km, guarding a degenerate span.
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
  # @return [String] A Mapbox pin overlay, e.g. "pin-l-rocket+18a644(-116.05,43.52)".
  def marker(which)
    coordinate = @track[which == :start ? "start_coord" : "end_coord"].to_a
    icon = @settings["#{which}_icon"].to_s.gsub(/[^a-z0-9-]/i, "")
    color = hex(@settings["#{which}_color"])

    "pin-l-#{icon}+#{color}(#{coordinate[0]},#{coordinate[1]})"
  end

  # The track itself, drawn from its vector tileset beneath the road labels.
  # @return [Hash, nil] nil when the tileset isn't published yet.
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

  # @return [String] Six lowercase hex digits, with any leading "#" and anything invalid stripped.
  def hex(color)
    digits = color.to_s.delete("#").gsub(/[^0-9a-f]/i, "").downcase.first(6)
    digits.length == 6 ? digits : "000000"
  end

  # Checkbox and JSON round-trips both reach here, so "0" and "false" have to read as false.
  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value) || false
  end

  # Retries transient failures (network errors and 5xx) a bounded number of times.
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

  # Builds a readable error from a failed response, falling back to the status code.
  def error_message_from(response)
    message = begin
      JSON.parse(response.body, symbolize_names: true)[:message]
    rescue JSON::ParserError, TypeError
      nil
    end
    message.presence || "Mapbox request failed with status #{response.code}"
  end
end
