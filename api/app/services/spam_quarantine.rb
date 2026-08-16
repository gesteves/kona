require "json"
require "securerandom"
require "time"

# Holds contact-form submissions Akismet flagged as spam, so a false positive can be reviewed and
# released instead of vanishing. Backed by a single Redis hash keyed on a generated message id.
#
# Not an ApplicationService: that base class exists for HTTP integrations, and this makes no
# network calls.
#
# ⚠️ One hash rather than a key per message, deliberately. Nothing else in this app enumerates the
# keyspace, and this Redis also backs the Sidekiq queues, so a SCAN here would be the first of its
# kind. The trade is that retention is enforced in Ruby rather than by a Redis TTL — which is why
# #store prunes as well as #all: pruning on the write path is what bounds growth when nobody opens
# the page.
class SpamQuarantine
  # Redis hash: field = message id, value = the JSON payload.
  REDIS_KEY = "contact:spam".freeze

  # How long a flagged message is kept before it's dropped.
  RETENTION = 30.days

  # A second bound, in case a flood outruns the age cutoff. Oldest are trimmed first.
  MAX_ENTRIES = 200

  # Quarantines one flagged submission.
  # @param name [String] The sender's name.
  # @param email [String] The sender's email.
  # @param message [String] The message body.
  # @param context [Hash] The proxy-forwarded sender context (ip, user_agent, city, region,
  #   country), exactly as ContactMailJob received it.
  # @return [String] The generated message id.
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

  # Every quarantined message, newest first, with expired ones dropped along the way.
  # @return [Array<Hash>] String-keyed payloads as written by #store.
  def all
    prune.sort_by { |entry| entry["received_at"].to_s }.reverse
  end

  # Removes a message and returns it, so the caller can act on it exactly once.
  #
  # ⚠️ The HDEL return value is the guard, not the HGET. Turbo, a double click, or a bfcache
  # replay can fire "Not spam" twice; releasing on the read alone would deliver the email twice.
  # Only the caller whose delete actually removed the field gets the payload back.
  #
  # @param id [String] The message id.
  # @return [Hash, nil] The payload, or nil if it was already gone.
  def take(id)
    raw = $redis.hget(REDIS_KEY, id)
    return nil if raw.blank?
    return nil unless delete(id)

    parse(raw)
  end

  # @param id [String] The message id.
  # @return [Boolean] Whether a message was actually removed.
  def delete(id)
    $redis.hdel(REDIS_KEY, id).to_i.positive?
  end

  # @return [Integer] How many messages are quarantined, including any not yet pruned.
  def count
    $redis.hlen(REDIS_KEY).to_i
  end

  private

  # Drops expired and unparseable entries, then trims back to MAX_ENTRIES oldest-first.
  # @return [Array<Hash>] The surviving payloads, unsorted.
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

    # Oldest first, so the overflow to drop is the front of the list.
    live.sort_by! { |_id, _payload, timestamp| timestamp }
    overflow = live.shift([ live.size - MAX_ENTRIES, 0 ].max)
    doomed.concat(overflow.map(&:first))

    $redis.hdel(REDIS_KEY, *doomed) if doomed.any?
    live.map { |_id, payload, _timestamp| payload }
  end

  # A malformed field is dropped rather than raised on — one bad entry must not take down the
  # whole page. Same posture as RelatedArticles#parse_vector.
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
