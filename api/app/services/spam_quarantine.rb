require "json"
require "securerandom"
require "time"

# Holds each contact-form submission that Akismet marks as spam. Thus the owner can read a correct
# message that Akismet marked and send it, and the message does not go away. One Redis hash holds
# them, with a message id as the key of each field.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call.
#
# ⚠️ There is one hash, and not one key for each message, on purpose. No other code in this app
# reads the full keyspace, and this Redis also holds the Sidekiq queues. Thus a SCAN here would be
# the first one. The cost is that the Ruby code, and not a Redis TTL, removes an old message. For
# that reason #store also removes old messages, as #all does: the removal on the write path is what
# limits the growth when nobody opens the page.
class SpamQuarantine
  # The Redis hash: the field is the message id, and the value is the JSON payload.
  REDIS_KEY = "contact:spam".freeze

  # The time that a marked message stays before the code removes it.
  RETENTION = 30.days

  # A second limit, for a large number of messages in a short time. The oldest go first.
  MAX_ENTRIES = 200

  # Holds one marked submission.
  # @param name [String] The name of the sender.
  # @param email [String] The email address of the sender.
  # @param message [String] The body of the message.
  # @param context [Hash] The sender data that the proxy sends (ip, user_agent, city, region, and
  #   country), as ContactMailJob got it.
  # @return [String] The new message id.
  def store(name:, email:, message:, context: {})
    id = SecureRandom.uuid

    $redis.hset(REDIS_KEY, id, {
      "id" => id,
      "name" => name,
      "email" => email,
      "message" => message,
      "context" => context || {},
      "received_at" => Time.now.utc.iso8601
    }.to_json)

    prune
    id
  end

  # All the messages that this class holds, the newest first. It also removes each message that
  # expired.
  # @return [Array<Hash>] The payloads with string keys, as #store writes them.
  def all
    prune.sort_by { |entry| entry["received_at"].to_s }.reverse
  end

  # Removes a message and returns it. Thus the caller can act on it one time only.
  #
  # ⚠️ The return value of the HDEL is the check, and not the HGET. Turbo, two clicks, or a bfcache
  # replay can send "Not spam" two times. An action on the read alone would send the email two
  # times. Only the caller whose delete removed the field gets the payload.
  #
  # @param id [String] The message id.
  # @return [Hash, nil] The payload, or nil if the message was already gone.
  def take(id)
    raw = $redis.hget(REDIS_KEY, id)
    return nil if raw.blank?
    return nil unless delete(id)

    parse(raw)
  end

  # @param id [String] The message id.
  # @return [Boolean] True if the code removed a message.
  def delete(id)
    $redis.hdel(REDIS_KEY, id).to_i.positive?
  end

  # @return [Integer] The number of messages that this class holds, and this includes each old
  #   message that the code did not remove.
  def count
    $redis.hlen(REDIS_KEY).to_i
  end

  private

  # Removes each entry that expired and each entry that the code cannot parse, then removes the
  # oldest entries until MAX_ENTRIES stay.
  # @return [Array<Hash>] The payloads that stay, in no order.
  def prune
    entries = $redis.hgetall(REDIS_KEY)
    return [] if entries.blank?

    cutoff = RETENTION.ago
    doomed = []
    live = []

    entries.each do |id, raw|
      payload = parse(raw)
      timestamp = payload && received_at(payload)

      if timestamp.nil? || timestamp < cutoff
        doomed << id
      else
        live << [ id, payload, timestamp ]
      end
    end

    # The oldest is first, thus the entries to remove are at the start of the list.
    live.sort_by! { |_id, _payload, timestamp| timestamp }
    overflow = live.shift([ live.size - MAX_ENTRIES, 0 ].max)
    doomed.concat(overflow.map(&:first))

    $redis.hdel(REDIS_KEY, *doomed) if doomed.any?
    live.map { |_id, payload, _timestamp| payload }
  end

  # The code removes a field with an incorrect shape and does not raise. One bad entry must not
  # stop the full page. RelatedArticles#parse_vector has the same rule.
  # @return [Hash, nil]
  def parse(raw)
    payload = JSON.parse(raw.to_s)
    payload.is_a?(Hash) ? payload : nil
  rescue JSON::ParserError
    nil
  end

  # @return [Time, nil]
  def received_at(payload)
    Time.iso8601(payload["received_at"].to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
