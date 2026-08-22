require "json"
require "tempfile"

# Uploads a track to Mapbox as a private vector tileset, with the Mapbox Tiling Service (MTS).
# Thus the Static Images API can draw it as a layer. The recipe names the layer (LAYER_NAME), thus
# the source-layer of the tileset is always the same and does not come from a file name.
#
# It is not an ApplicationService, because no code here is a cacheable read.
# @see https://docs.mapbox.com/api/maps/mapbox-tiling-service/
class MapboxTileset
  API = "https://api.mapbox.com/tilesets/v1".freeze

  # The layer key in the recipe. It becomes the source-layer name of the tileset.
  LAYER_NAME = "track".freeze

  # Mapbox permits a maximum of 64 characters in the readable tileset name, and it permits only
  # letters, digits, spaces, "-", "_", and ".".
  MAX_NAME_LENGTH = 64

  # An MTS publish job is asynchronous. Read the job status until the job ends.
  #
  # ⚠️ A track with approximately 9,000 points takes approximately three and a half minutes to
  # publish, thus the timeout has much less extra time than it looks. A stop raises, and the next
  # attempt then does a full upload again. Thus the timeout is long, on purpose. A worker thread
  # for this length of time is acceptable at concurrency 5 for a queue that only the owner fills.
  POLL_INTERVAL = 5   # seconds between job-status polls
  POLL_TIMEOUT  = 600 # give up after this many seconds
  HTTP_TIMEOUT  = 30  # per-request timeout

  class ConfigurationError < StandardError; end

  # @return [Boolean] True if the credentials for an upload are available. Nothing runs without
  #   them, thus dev and CI do nothing, as they do for the R2 mirror.
  def self.configured?
    ENV["MAPBOX_USERNAME"].present? && ENV["MAPBOX_SECRET_TOKEN"].present?
  end

  def initialize
    @username = ENV["MAPBOX_USERNAME"]
    @token = ENV["MAPBOX_SECRET_TOKEN"]

    raise ConfigurationError, "Mapbox username is missing! Set MAPBOX_USERNAME." if @username.blank?
    raise ConfigurationError, "Mapbox secret token is missing! Set MAPBOX_SECRET_TOKEN." if @token.blank?
  end

  # Uploads the coordinates as a tileset source, makes the tileset from a recipe, publishes it,
  # and waits for the publish job to end.
  #
  # You can do this more than one time, and the retry policy of the job depends on that: the source
  # upload replaces the source and does not add to it, a tileset that exists is a success, and a
  # publish only makes a new job.
  #
  # @param id [String] The Mapbox tileset and source id (32 characters or less, [-_] only).
  # @param name [String] A readable name for the tileset.
  # @param coordinates [Array<Array<Float>>] The track points, as [lon, lat] pairs.
  # @return [String] The full tileset id ("username.id").
  def create_from_coordinates!(id:, name:, coordinates:)
    upload_source(id, coordinates)
    create_tileset(id, name)
    wait_for_job(id, publish(id))
    "#{@username}.#{id}"
  end

  # Finds a tileset that is already published.
  # @param id [String] The Mapbox tileset id, with no user name at the start.
  # @return [Array(String, String), nil] [full_id, source_layer] if the tileset exists and the code
  #   can render it, or nil.
  def find(id)
    response = HTTParty.get(
      "https://api.mapbox.com/v4/#{@username}.#{id}.json",
      query: { access_token: @token },
      timeout: HTTP_TIMEOUT
    )
    return nil unless response.success?

    layer = Array(JSON.parse(response.body)["vector_layers"]).first&.dig("id")
    return nil if layer.blank?

    [ "#{@username}.#{id}", layer ]
  rescue JSON::ParserError
    nil
  end

  # Removes a tileset and the source that it comes from.
  #
  # ⚠️ It removes both, on purpose. A delete of the tileset alone leaves its source, which still
  # uses the storage of the account and does not appear in the tileset list.
  #
  # A 404 from one of them is a success, because the object is gone. Each other error raises. Thus
  # a delete that fails does not remove the local record and keep the remote one.
  #
  # @param id [String] The Mapbox tileset id, with no user name at the start.
  # @return [true]
  def destroy!(id)
    delete!("#{API}/#{@username}.#{id}", "delete tileset")
    delete!("#{API}/sources/#{@username}/#{id}", "delete tileset source")
    true
  end

  private

  def delete!(url, action)
    response = HTTParty.delete(url, query: { access_token: @token }, timeout: HTTP_TIMEOUT)
    return if response.success? || response.code == 404

    raise upload_error(action, response)
  end

  # Makes GeoJSON with one line for each item (here, one LineString Feature on one line) and PUTs
  # it as a tileset source. It replaces a source with the same id. A POST would add to a source
  # that exists and would collect old tracks. A PUT replaces, thus a second upload gives only this
  # track.
  def upload_source(id, coordinates)
    feature = {
      type: "Feature",
      properties: {},
      geometry: { type: "LineString", coordinates: coordinates }
    }

    Tempfile.create([ id, ".geojson.ld" ]) do |file|
      file.write("#{feature.to_json}\n")
      file.rewind
      response = HTTParty.put(
        "#{API}/sources/#{@username}/#{id}",
        query: { access_token: @token },
        body: { file: file },
        multipart: true,
        timeout: HTTP_TIMEOUT
      )
      raise upload_error("upload tileset source", response) unless response.success?
    end
  end

  # Makes the tileset from a recipe. The LAYER_NAME key sets the source-layer name. A second run
  # gets an "already exists" error, which is not a problem: the code refreshed the source above and
  # the publish makes the tiles again. Thus the code continues.
  def create_tileset(id, name)
    recipe = {
      version: 1,
      layers: {
        LAYER_NAME => {
          source: "mapbox://tileset-source/#{@username}/#{id}",
          minzoom: 0,
          maxzoom: 16
        }
      }
    }

    response = HTTParty.post(
      "#{API}/#{@username}.#{id}",
      query: { access_token: @token },
      headers: { "Content-Type" => "application/json" },
      body: { recipe: recipe, name: sanitize_name(name), private: true }.to_json,
      timeout: HTTP_TIMEOUT
    )

    return if response.success?
    return if already_exists?(response)

    raise upload_error("create tileset", response)
  end

  # Changes a readable name into the set of characters that Mapbox permits. It changes the text to
  # ASCII, thus "Coeur d'Alene" loses its curly apostrophe and its accents. It removes each
  # character outside [letter, digit, space, -, _, .], makes each group of spaces into one space,
  # and cuts the result at MAX_NAME_LENGTH.
  def sanitize_name(name)
    ActiveSupport::Inflector.transliterate(name.to_s)
      .gsub(/[^a-zA-Z0-9 \-_.]/, "")
      .squish
      .first(MAX_NAME_LENGTH)
  end

  # Starts a publish job for the tileset and returns its job id.
  def publish(id)
    response = HTTParty.post(
      "#{API}/#{@username}.#{id}/publish",
      query: { access_token: @token },
      timeout: HTTP_TIMEOUT
    )
    raise upload_error("publish tileset", response) unless response.success?

    JSON.parse(response.body)["jobId"]
  end

  # Reads the publish job status until the job is successful, fails, or reaches the timeout.
  def wait_for_job(id, job_id)
    waited = 0
    loop do
      response = HTTParty.get(
        "#{API}/#{@username}.#{id}/jobs/#{job_id}",
        query: { access_token: @token },
        timeout: HTTP_TIMEOUT
      )
      raise upload_error("check tileset job status", response) unless response.success?

      job = JSON.parse(response.body)
      case job["stage"]
      when "success"
        return
      when "failed"
        raise "Mapbox tileset publish failed: #{Array(job['errors']).join('; ').presence || 'unknown error'}"
      end

      raise "Mapbox tileset publish timed out after #{POLL_TIMEOUT}s" if waited >= POLL_TIMEOUT

      sleep(POLL_INTERVAL)
      waited += POLL_INTERVAL
    end
  end

  # A tileset create for an id that exists returns a 4xx with a message that says that it already
  # exists. Count that as a success, thus you can run this more than one time.
  def already_exists?(response)
    parsed_message(response).to_s.match?(/already exists/i)
  end

  # Makes a readable error for an MTS request that failed.
  def upload_error(action, response)
    detail = parsed_message(response).presence || "status #{response.code}"
    "Mapbox failed to #{action}: #{detail}"
  end

  # Gets a `message` from a JSON error body. If there is none, it gives nil.
  def parsed_message(response)
    JSON.parse(response.body)["message"]
  rescue JSON::ParserError, TypeError
    nil
  end
end
