require "time"

# The GPX tracks that a user uploads on the Maps page of the admin, and their Mapbox tilesets.
#
# To render a map, the code needs the bounding box of the track, its two end points, and its sport.
# The GPX parse gives all of them. The code removes the upload after Mapbox has the geometry, thus
# it keeps those values here. Without them the settings screen could not put the pins on a track
# from last week.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call.
#
# One Redis hash holds the records (refer to JsonHashStore), with the track id as the field.
class TrackLibrary
  # The Redis hash: the field is the track id, and the value is the JSON record.
  REDIS_KEY = "maps:tracks".freeze

  # Holds the coordinates that an upload in the queue still needs.
  PENDING_KEY_PREFIX = "maps:pending:".freeze
  PENDING_TTL = 1.hour

  # This is a limit on growth, and not a retention rule. A track goes away only when the owner
  # deletes it.
  MAX_ENTRIES = 100

  STATUSES = %w[processing ready failed].freeze

  # Stores a new upload after the parse, and holds its coordinates for the job.
  #
  # ⚠️ The coordinates go in their own key, and not in the record or in the arguments of the job.
  # `app` and `worker` are different fly machines, thus the worker cannot read a temporary file
  # from the request. And a track with 9,000 points is a few hundred KB, which is too large for a
  # record that the index page loads in full, and too large for a Sidekiq argument.
  #
  # @param track [GpxTrack] The upload after the parse.
  # @return [String] The track id.
  def stage(track)
    id = track.id

    write(id, {
      "id" => id,
      "title" => track.title,
      "activity_type" => track.activity_type,
      "activity_start" => track.activity_start&.utc&.iso8601,
      "bounds" => track.bounds.transform_keys(&:to_s),
      "start_coord" => track.start_coord,
      "end_coord" => track.end_coord,
      "status" => "processing",
      "uploaded_at" => Time.now.utc.iso8601,
      "settings" => StaticMap.defaults_for(track.start_icon)
    })

    $redis.setex(pending_key(id), PENDING_TTL.to_i, track.coordinates.to_json)
    prune
    id
  end

  # The coordinates for a track, if they did not expire.
  # @param id [String]
  # @return [Array<Array<Float>>, nil]
  def pending_coordinates(id)
    raw = $redis.get(pending_key(id))
    return nil if raw.blank?

    coordinates = JSON.parse(raw)
    coordinates.is_a?(Array) && coordinates.any? ? coordinates : nil
  rescue JSON::ParserError
    nil
  end

  # @param id [String]
  def discard_pending(id)
    $redis.del(pending_key(id))
  end

  # All the tracks, the newest first.
  # @return [Array<Hash>]
  def all
    records.read_all.values.sort_by { |record| record["uploaded_at"].to_s }.reverse
  end

  # @param id [String]
  # @return [Hash, nil]
  def find(id)
    records.read(id)
  end

  # id => status, for the poll endpoint of the page. It is not the full records, on purpose,
  # because the page gets this each few seconds during an upload.
  # @return [Hash{String => String}]
  def statuses
    all.to_h { |record| [ record["id"], record["status"].to_s ] }
  end

  # Changes one record in place.
  # @param id [String]
  # @param changes [Hash] The changes to put on top of the stored record.
  # @return [Hash, nil] The new record, or nil if the record is gone.
  def update(id, changes)
    record = find(id)
    return nil if record.nil?

    write(id, record.merge(changes.transform_keys(&:to_s)))
  end

  # Replaces the render settings of a track. It keeps only the keys that are settings, thus a form
  # that an attacker makes cannot write other fields into the record.
  # @param id [String]
  # @param settings [Hash]
  # @return [Hash, nil] The updated record.
  def update_settings(id, settings)
    record = find(id)
    return nil if record.nil?

    allowed = settings.to_h.stringify_keys.slice(*self.class.setting_keys)
    write(id, record.merge("settings" => (record["settings"] || {}).merge(allowed)))
  end

  # @return [Array<String>] All the render-setting keys that the code knows.
  def self.setting_keys
    StaticMap::DEFAULTS.keys
  end

  # @param id [String]
  # @return [Boolean] True if the code removed a record.
  def delete(id)
    discard_pending(id)
    records.delete(id).positive?
  end

  # @return [Integer]
  def count
    records.count
  end

  private

  def records
    @records ||= JsonHashStore.new(REDIS_KEY)
  end

  def write(id, record)
    records.write(id, record)
  end

  def pending_key(id)
    "#{PENDING_KEY_PREFIX}#{id}"
  end

  # Removes the oldest tracks if the library becomes too large. The spam quarantine is different:
  # there is no age limit here, because the owner can render an old track again.
  def prune
    records.prune(max: MAX_ENTRIES, sort_by: ->(record) { record["uploaded_at"].to_s })
  end
end
