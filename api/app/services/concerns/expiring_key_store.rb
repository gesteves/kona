require "securerandom"

# A store with one Redis hash for each record, a random id, and a TTL. StagedUpload and SocialPhotos
# both keep their bytes this way: a record that the owner never uses must go away by itself.
#
# The class that includes this supplies `KEY_PREFIX`. It keeps its own `store` and its own `fetch`,
# because the fields of a record are different in each store.
#
# ⚠️ The id goes into a Redis key, and it comes back from a form and from a URL. `id?` is the check
# that keeps each other shape out of a key, thus each method here calls it first.
module ExpiringKeyStore
  extend ActiveSupport::Concern

  # The shape of an id, which `#write_new` makes.
  ID_PATTERN = /\A\h{32}\z/

  class_methods do
    # @param value [Object]
    # @return [Boolean] True when the value has the shape of an id.
    def id?(value)
      value.is_a?(String) && value.match?(ID_PATTERN)
    end
  end

  # @param id [String]
  # @return [Boolean]
  def exists?(id)
    self.class.id?(id) && $redis.exists?(key_for(id))
  end

  # @param ids [Array<String>]
  # @return [void]
  def discard(ids)
    keys = Array(ids).select { |id| self.class.id?(id) }.map { |id| key_for(id) }
    $redis.del(*keys) if keys.any?
  end

  private

  # Writes one new record under a new id.
  # @param ttl [ActiveSupport::Duration, Integer] How long the record stays.
  # @param fields [Hash] The fields of the Redis hash.
  # @return [String] The id.
  def write_new(ttl, fields)
    id = SecureRandom.hex(16)
    key = key_for(id)

    # ⚠️ Both in one transaction, thus no key can exist with no TTL.
    $redis.multi do |tx|
      tx.hset(key, *fields.flatten)
      tx.expire(key, ttl.to_i)
    end
    id
  end

  def key_for(id)
    "#{self.class::KEY_PREFIX}#{id}"
  end
end
