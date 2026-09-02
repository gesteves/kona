require "securerandom"
require "time"

# Holds each contact-form submission that Akismet marks as spam. Thus the owner can read a correct
# message that Akismet marked and send it, and the message does not go away. One Redis hash holds
# them (refer to JsonHashStore), with a message id as the key of each field.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call.
#
# ⚠️ Ruby applies the 30-day retention, and not a Redis TTL. Thus #store also removes old messages,
# as #all does: the removal on the write path is what limits the growth when nobody opens the page.
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

    records.write(id, {
      "id" => id,
      "name" => name,
      "email" => email,
      "message" => message,
      "context" => context || {},
      "received_at" => Time.now.utc.iso8601
    })

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
    payload = records.read(id)
    return nil if payload.nil?
    return nil unless delete(id)

    payload
  end

  # @param id [String] The message id.
  # @return [Boolean] True if the code removed a message.
  def delete(id)
    records.delete(id).positive?
  end

  # @return [Integer] The number of messages that this class holds, and this includes each old
  #   message that the code did not remove.
  def count
    records.count
  end

  private

  def records
    @records ||= JsonHashStore.new(REDIS_KEY)
  end

  # Removes each entry that expired and each entry that the code cannot parse, then removes the
  # oldest entries until MAX_ENTRIES stay.
  # @return [Array<Hash>] The payloads that stay, in no order.
  def prune
    cutoff = RETENTION.ago
    records.prune(
      max: MAX_ENTRIES,
      sort_by: ->(payload) { received_at(payload) },
      keep: ->(payload) { received_at(payload)&.>=(cutoff) || false }
    )
  end

  # @return [Time, nil]
  def received_at(payload)
    Time.iso8601(payload["received_at"].to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
