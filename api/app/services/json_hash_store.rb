require "json"

# One Redis hash of JSON records: the field is the id of a record, and the value is its JSON.
# SpamQuarantine and TrackLibrary both keep their records this way.
#
# ⚠️ There is one hash, and not one key for each record, on purpose. No other code in this app
# reads the full keyspace, and this Redis also holds the Sidekiq queues, thus a SCAN would be the
# first one. The cost is that Ruby, and not a Redis TTL, removes an old record: `prune` does that.
class JsonHashStore
  # @param key [String] The Redis key of the hash.
  def initialize(key)
    @key = key
  end

  # @param id [String] The field.
  # @param record [Hash] The record. It must be JSON-serializable.
  # @return [Hash] The record.
  def write(id, record)
    $redis.hset(@key, id, record.to_json)
    record
  end

  # @param id [String]
  # @return [Hash, nil] The record, or nil when it is absent or cannot be read.
  def read(id)
    parse($redis.hget(@key, id))
  end

  # @return [Hash{String => Hash}] Each record that the code can read, by id, in no order.
  def read_all
    entries = $redis.hgetall(@key)
    return {} if entries.blank?

    entries.each_with_object({}) do |(id, raw), records|
      record = parse(raw)
      records[id] = record if record
    end
  end

  # @param ids [Array<String>]
  # @return [Integer] The number of records that the code removed.
  def delete(*ids)
    return 0 if ids.empty?

    $redis.hdel(@key, *ids).to_i
  end

  # @return [Integer] The number of records, and this includes each one that the code cannot read.
  def count
    $redis.hlen(@key).to_i
  end

  # Removes each record that the code cannot read, each record that `keep` refuses, and then the
  # oldest records above `max`.
  # @param max [Integer] The most records that stay.
  # @param sort_by [Proc] Gives the age key of a record. The smallest is the oldest.
  # @param keep [Proc, nil] Gives false for a record to remove, for example one past a retention
  #   time. Nil keeps each record.
  # @return [Array<Hash>] The records that stay, in no order.
  def prune(max:, sort_by:, keep: nil)
    entries = $redis.hgetall(@key)
    return [] if entries.blank?

    doomed = []
    live = []
    entries.each do |id, raw|
      record = parse(raw)
      if record && (keep.nil? || keep.call(record))
        live << [ id, record ]
      else
        doomed << id
      end
    end

    # The oldest is first, thus the records to remove are at the start of the list.
    live.sort_by! { |_id, record| sort_by.call(record) }
    overflow = live.shift([ live.size - max, 0 ].max)
    doomed.concat(overflow.map(&:first))

    $redis.hdel(@key, *doomed) if doomed.any?
    live.map(&:last)
  end

  private

  # The code removes a record with an incorrect shape and does not raise. One bad entry must not
  # stop the full page.
  # @return [Hash, nil]
  def parse(raw)
    return nil if raw.blank?

    record = JSON.parse(raw.to_s)
    record.is_a?(Hash) ? record : nil
  rescue JSON::ParserError
    nil
  end
end
