require 'httparty'
require 'json'
require 'tempfile'
require 'active_support/all'

# Uploads a GPX track to Mapbox as a private vector tileset using the Mapbox
# Tiling Service (MTS), so map generation no longer needs a manually-uploaded
# tileset. The recipe names the layer explicitly (LAYER_NAME), so the resulting
# tileset's source-layer is deterministic rather than derived from a file name.
# @see https://docs.mapbox.com/api/maps/mapbox-tiling-service/
class MapboxTileset
  API = 'https://api.mapbox.com/tilesets/v1'

  # The recipe layer key, which becomes the tileset's source-layer name.
  LAYER_NAME = 'track'

  # MTS publish jobs are asynchronous; poll until the job finishes.
  POLL_INTERVAL = 5   # seconds between job-status polls
  POLL_TIMEOUT  = 300 # give up after this many seconds
  HTTP_TIMEOUT  = 30  # per-request timeout

  def initialize(username:, token:)
    raise 'Mapbox username is missing! Set MAPBOX_USERNAME.' if username.blank?
    raise 'Mapbox secret token is missing! Set MAPBOX_SECRET_TOKEN.' if token.blank?

    @username = username
    @token = token
  end

  # Uploads the coordinates as a tileset source, creates the tileset from a
  # recipe, publishes it, and waits for the publish job to finish.
  # @param id [String] The Mapbox-safe tileset/source id (≤ 32 chars, [-_] only).
  # @param name [String] A human-readable name for the tileset.
  # @param coordinates [Array<Array<Float>>] Track points as [lon, lat] pairs.
  # @return [String] The full tileset id ("username.id").
  def create_from_coordinates!(id:, name:, coordinates:)
    upload_source(id, coordinates)
    create_tileset(id, name)
    job_id = publish(id)
    wait_for_job(id, job_id)
    "#{@username}.#{id}"
  end

  # Looks up an already-published tileset so callers can skip a re-upload when
  # only the (render-time) image settings changed. Returns [full_id, source_layer]
  # if the tileset exists and is renderable, otherwise nil.
  # @param id [String] The Mapbox-safe tileset id (without the username prefix).
  # @return [Array(String, String), nil]
  def find(id)
    response = HTTParty.get(
      "https://api.mapbox.com/v4/#{@username}.#{id}.json",
      query: { access_token: @token },
      timeout: HTTP_TIMEOUT
    )
    return nil unless response.success?

    layer = Array(JSON.parse(response.body)['vector_layers']).first&.dig('id')
    return nil if layer.blank?

    ["#{@username}.#{id}", layer]
  rescue JSON::ParserError
    nil
  end

  private

  # Builds line-delimited GeoJSON (a single LineString Feature on one line) and
  # POSTs it as a tileset source, replacing any existing source with the same id.
  def upload_source(id, coordinates)
    feature = {
      type: 'Feature',
      properties: {},
      geometry: { type: 'LineString', coordinates: coordinates }
    }

    Tempfile.create([id, '.geojson.ld']) do |file|
      file.write("#{feature.to_json}\n")
      file.rewind
      response = HTTParty.post(
        "#{API}/sources/#{@username}/#{id}",
        query: { access_token: @token },
        body: { file: file },
        multipart: true,
        timeout: HTTP_TIMEOUT
      )
      raise upload_error('upload tileset source', response) unless response.success?
    end
  end

  # Creates the tileset from a recipe. The LAYER_NAME key fixes the source-layer
  # name. Re-runs hit an "already exists" error, which is benign — the source was
  # just refreshed above and publishing will re-tile it, so we continue.
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
      headers: { 'Content-Type' => 'application/json' },
      body: { recipe: recipe, name: name, private: true }.to_json,
      timeout: HTTP_TIMEOUT
    )

    return if response.success?
    return if already_exists?(response)

    raise upload_error('create tileset', response)
  end

  # Triggers a publish job for the tileset and returns its job id.
  def publish(id)
    response = HTTParty.post(
      "#{API}/#{@username}.#{id}/publish",
      query: { access_token: @token },
      timeout: HTTP_TIMEOUT
    )
    raise upload_error('publish tileset', response) unless response.success?

    JSON.parse(response.body)['jobId']
  end

  # Polls the publish job until it succeeds, fails, or times out.
  def wait_for_job(id, job_id)
    waited = 0
    loop do
      response = HTTParty.get(
        "#{API}/#{@username}.#{id}/jobs/#{job_id}",
        query: { access_token: @token },
        timeout: HTTP_TIMEOUT
      )
      raise upload_error('check tileset job status', response) unless response.success?

      job = JSON.parse(response.body)
      case job['stage']
      when 'success'
        return
      when 'failed'
        raise "Mapbox tileset publish failed: #{Array(job['errors']).join('; ').presence || 'unknown error'}"
      end

      raise "Mapbox tileset publish timed out after #{POLL_TIMEOUT}s" if waited >= POLL_TIMEOUT
      sleep(POLL_INTERVAL)
      waited += POLL_INTERVAL
    end
  end

  # A tileset create against an existing id returns a 4xx whose message says it
  # already exists; treat that as success so re-runs are idempotent.
  def already_exists?(response)
    message = parsed_message(response).to_s
    message.match?(/already exists/i)
  end

  # Builds a human-readable error for a failed MTS request.
  def upload_error(action, response)
    detail = parsed_message(response).presence || "status #{response.code}"
    "Mapbox failed to #{action}: #{detail}"
  end

  # Extracts a `message` from a JSON error body, falling back to nil.
  def parsed_message(response)
    JSON.parse(response.body)['message']
  rescue JSON::ParserError, TypeError
    nil
  end
end
