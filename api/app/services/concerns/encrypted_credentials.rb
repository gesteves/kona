# The parts that each credential store shares: the Redis hash, the encryption of a secret field,
# the record of a refused token refresh, and the removal of the store.
#
# An includer declares `REDIS_KEY`, the hash, and `ENCRYPTION_SALT`, the salt of its key.
#
# ⚠️ Each secret is encrypted at rest with `secret_key_base`, that is, `RAILS_MASTER_KEY`. This
# Redis also holds the Sidekiq queues, thus the key is at a place that Redis access alone cannot
# reach, on purpose.
#
# ⚠️ **Never change the `ENCRYPTION_SALT` of a store.** The salt is part of the key, thus a new salt
# makes each stored secret unreadable, `decrypt` then gives nil, and each page says "not connected"
# until the owner connects the account again.
module EncryptedCredentials
  extend ActiveSupport::Concern

  class_methods do
    # Removes the full store. The owner must connect the account again.
    # @return [void]
    def clear
      $redis.del(self::REDIS_KEY)
      nil
    end

    # Records a refused token refresh in the "refresh_error" field of the hash. Refer to
    # RefreshError for the rule. ⚠️ It has no TTL: only a token that arrives, or the removal of the
    # store, takes it away, because the problem is real until one of those occurs.
    # @param code [Integer, String] The HTTP status from the token endpoint.
    # @return [void]
    def record_refresh_error(code)
      return unless RefreshError.refused?(code)

      $redis.hset(self::REDIS_KEY, "refresh_error", RefreshError.encode(code))
      nil
    end

    private

    # Removes the record of a refused refresh. A store calls this when it writes a token: a token
    # that arrives is the correction.
    # @return [void]
    def forget_refresh_error
      $redis.hdel(self::REDIS_KEY, "refresh_error")
      nil
    end

    # @param value [String, nil] An ISO8601 time.
    # @return [Time, nil]
    def parse_time(value)
      Time.iso8601(value) if value.present?
    rescue ArgumentError
      nil
    end

    # @param value [String] A secret.
    # @return [String] The encrypted message.
    def encrypt(value)
      encryptor.encrypt_and_sign(value.to_s)
    end

    # ⚠️ This returns nil and does not raise when the code cannot read the message. A new
    # RAILS_MASTER_KEY must give "not connected", which the owner corrects with a new connection in
    # the admin. It must not give an exception on each page that shows the status.
    # @param value [String, nil] The encrypted message.
    # @return [String, nil]
    def decrypt(value)
      return if value.blank?
      encryptor.decrypt_and_verify(value).presence
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
      # A message from another key. Each other error is a bug, and it must show.
      nil
    end

    # @return [ActiveSupport::MessageEncryptor]
    def encryptor
      @encryptor ||= ActiveSupport::MessageEncryptor.new(
        Rails.application.key_generator.generate_key(self::ENCRYPTION_SALT, ActiveSupport::MessageEncryptor.key_len)
      )
    end
  end
end
