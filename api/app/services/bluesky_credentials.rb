# The Bluesky handle and app password used to open a PDS session, entered on the admin's
# Connected apps page and held in Redis.
#
# Not an ApplicationService: that base class exists for HTTP integrations, and this makes no
# network calls. Validating a credential pair is StandardSite's job, since it's the thing that
# knows how to open a session.
#
# ⚠️ The app password is encrypted at rest. It's an account-level credential that works from
# anywhere with no client binding, and this Redis also backs the Sidekiq queues, so the key
# (derived from secret_key_base, i.e. RAILS_MASTER_KEY) deliberately lives somewhere Redis
# access alone can't reach.
class BlueskyCredentials
  # Redis hash: "handle" plaintext, "app_password" encrypted.
  REDIS_KEY = "bluesky:credentials".freeze

  Credentials = Data.define(:handle, :app_password) do
    # @return [Boolean] Whether both halves are present.
    def usable? = handle.present? && app_password.present?
  end

  # The credentials to authenticate with.
  # @return [Credentials] With nil members when none are stored.
  def self.fetch
    stored = $redis.hgetall(REDIS_KEY) || {}
    Credentials.new(handle: stored["handle"].presence, app_password: decrypt(stored["app_password"]))
  end

  # @return [Boolean] Whether a usable pair has been entered in the admin.
  def self.stored? = fetch.usable?

  # Replaces the stored pair. Callers must validate it first — nothing here checks that the
  # credentials actually open a session.
  # @param handle [String]
  # @param app_password [String]
  # @return [void]
  def self.store(handle:, app_password:)
    $redis.hset(REDIS_KEY, "handle", handle.to_s.strip, "app_password", encryptor.encrypt_and_sign(app_password.to_s))
    nil
  end

  # Forgets the stored pair, leaving the integration inert until one is entered again.
  # @return [void]
  def self.clear
    $redis.del(REDIS_KEY)
    nil
  end

  # ⚠️ Returns nil rather than raising when the message can't be read — a rotated
  # RAILS_MASTER_KEY must degrade to "not connected", which the admin can fix by re-entering the
  # credentials, not to an exception on every page that renders the status.
  # @param value [String, nil] The encrypted message.
  # @return [String, nil]
  def self.decrypt(value)
    return if value.blank?
    encryptor.decrypt_and_verify(value).presence
  rescue StandardError
    nil
  end
  private_class_method :decrypt

  # @return [ActiveSupport::MessageEncryptor]
  def self.encryptor
    @encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key("bluesky credentials", ActiveSupport::MessageEncryptor.key_len)
    )
  end
  private_class_method :encryptor
end
