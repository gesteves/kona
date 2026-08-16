require "json"
require "time"

# The GPX tracks uploaded through the admin's Maps page, and their Mapbox tilesets.
#
# Rendering a map needs the track's bounding box, its two endpoints, and its sport — all of which
# come from parsing the GPX. The upload itself is thrown away once Mapbox has the geometry, so
# those derived values are kept here instead; without them the settings screen couldn't place the
# pins on a track uploaded last week.
#
# Not an ApplicationService: that base class exists for HTTP integrations, and this makes no
# network calls.
#
# ⚠️ One hash rather than a key per track, for the same reason as SpamQuarantine: nothing else in
# this app enumerates the keyspace, and this Redis also backs the Sidekiq queues, so a SCAN here
# would be the first of its kind.
class TrackLibrary
  # Redis hash: field = track id, value = the JSON record.
  REDIS_KEY = "maps:tracks".freeze

  # Staging for the coordinates a queued upload still needs.
  PENDING_KEY_PREFIX = "maps:pending:".freeze
  PENDING_TTL = 1.hour

  # A runaway guard, not a retention policy — a track is only gone when the owner deletes it.
  MAX_ENTRIES = 100

  STATUSES = %w[processing ready failed].freeze

  # Records a freshly parsed upload and stages its coordinates for the job.
  #
  # ⚠️ The coordinates go in their own key rather than into the record or the job's arguments.
  # `app` and `worker` are separate fly machines, so a tempfile written during the request isn't
  # there for the worker to read; and a 9,000-point track is a few hundred KB, which belongs
  # neither in a record the index page loads in full nor in a Sidekiq argument.
  #
  # @param track [GpxTrack] The parsed upload.
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

  # The coordinates staged for a track, if they haven't expired.
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

  # Every track, newest first.
  # @return [Array<Hash>]
  def all
    entries = $redis.hgetall(REDIS_KEY)
    return [] if entries.blank?

    entries.values.filter_map { |raw| parse(raw) }.sort_by { |record| record["uploaded_at"].to_s }.reverse
  end

  # @param id [String]
  # @return [Hash, nil]
  def find(id)
    parse($redis.hget(REDIS_KEY, id))
  end

  # id => status, for the page's polling endpoint. Deliberately not the full records: this is
  # fetched every few seconds while an upload is in flight.
  # @return [Hash{String => String}]
  def statuses
    all.to_h { |record| [ record["id"], record["status"].to_s ] }
  end

  # Applies changes to one record, in place.
  # @param id [String]
  # @param changes [Hash] Merged over the stored record.
  # @return [Hash, nil] The updated record, or nil if it's gone.
  def update(id, changes)
    record = find(id)
    return nil if record.nil?

    write(id, record.merge(changes.transform_keys(&:to_s)))
  end

  # Replaces a track's render settings, keeping only keys that are actually settings so a crafted
  # form can't write arbitrary fields into the record.
  # @param id [String]
  # @param settings [Hash]
  # @return [Hash, nil] The updated record.
  def update_settings(id, settings)
    record = find(id)
    return nil if record.nil?

    allowed = settings.to_h.stringify_keys.slice(*self.class.setting_keys)
    write(id, record.merge("settings" => (record["settings"] || {}).merge(allowed)))
  end

  # @return [Array<String>] Every recognized render-setting key.
  def self.setting_keys
    StaticMap::DEFAULTS.keys
  end

  # @param id [String]
  # @return [Boolean] Whether a record was actually removed.
  def delete(id)
    discard_pending(id)
    $redis.hdel(REDIS_KEY, id).to_i.positive?
  end

  # @return [Integer]
  def count
    $redis.hlen(REDIS_KEY).to_i
  end

  private

  def write(id, record)
    $redis.hset(REDIS_KEY, id, record.to_json)
    record
  end

  def pending_key(id)
    "#{PENDING_KEY_PREFIX}#{id}"
  end

  # Trims oldest-first if the library ever runs away. Unlike the spam quarantine there's no age
  # cutoff — an old track is still a track the owner might re-render.
  def prune
    entries = $redis.hgetall(REDIS_KEY)
    return if entries.blank?

    doomed = []
    live = []

    entries.each do |field, raw|
      record = parse(raw)
      record.nil? ? doomed << field : live << [ field, record["uploaded_at"].to_s ]
    end

    # Oldest first, so the overflow to drop is the front of the list.
    live.sort_by!(&:last)
    doomed.concat(live.first([ live.size - MAX_ENTRIES, 0 ].max).map(&:first))

    $redis.hdel(REDIS_KEY, *doomed) if doomed.any?
  end

  # A malformed record is dropped rather than raised on — one bad entry must not take down the
  # whole page. Same posture as SpamQuarantine#parse.
  # @return [Hash, nil]
  def parse(raw)
    return nil if raw.blank?

    record = JSON.parse(raw.to_s)
    record.is_a?(Hash) ? record : nil
  rescue JSON::ParserError
    nil
  end
end
