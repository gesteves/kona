# The Bluesky handle and app password used to open a PDS session, entered on the admin's
# Connected apps page and held in Redis, with the BLUESKY_* env vars as a fallback.
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

  # Where a resolved pair came from, so the admin can say which one is actually in use.
  # @!attribute [r] source
  #   @return [Symbol, nil] :admin, :environment, or nil when neither is usable.
  Credentials = Data.define(:handle, :app_password, :source) do
    # @return [Boolean] Whether both halves are present.
    def usable? = handle.present? && app_password.present?
  end

  # The credentials to authenticate with. Stored values outrank the environment, so entering a
  # pair in the admin supersedes the fly secrets without removing them.
  # @return [Credentials] With a nil source when neither pair is usable.
  def self.fetch
    stored = read_stored
    return stored if stored.usable?

    from_env = Credentials.new(
      handle: ENV["BLUESKY_HANDLE"].presence,
      app_password: ENV["BLUESKY_APP_PASSWORD"].presence,
      source: :environment
    )
    from_env.usable? ? from_env : Credentials.new(handle: nil, app_password: nil, source: nil)
  end

  # @return [Boolean] Whether a usable pair has been entered in the admin.
  def self.stored? = read_stored.usable?

  # Replaces the stored pair. Callers must validate it first — nothing here checks that the
  # credentials actually open a session.
  # @param handle [String]
  # @param app_password [String]
  # @return [void]
  def self.store(handle:, app_password:)
    $redis.hset(REDIS_KEY, "handle", handle.to_s.strip, "app_password", encryptor.encrypt_and_sign(app_password.to_s))
    nil
  end

  # Forgets the stored pair, falling resolution back to the environment.
  # @return [void]
  def self.clear
    $redis.del(REDIS_KEY)
    nil
  end

  # @return [Credentials] The stored pair, with a nil app_password if it can't be decrypted.
  def self.read_stored
    stored = $redis.hgetall(REDIS_KEY) || {}
    Credentials.new(
      handle: stored["handle"].presence,
      app_password: decrypt(stored["app_password"]),
      source: :admin
    )
  end
  private_class_method :read_stored

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
