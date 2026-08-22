# The Bluesky handle and app password that open a PDS session. The owner types them on the
# Connected apps page of the admin, and Redis holds them.
#
# This is not an ApplicationService, because that base class is for HTTP integrations and this
# class makes no network call. StandardSite checks a credential pair, because it is the class that
# opens a session.
#
# ⚠️ The app password is encrypted in the store. It is an account credential that works from each
# place, with no connection to one client, and this Redis also holds the Sidekiq queues. Thus the
# key, which comes from secret_key_base, that is, RAILS_MASTER_KEY, is at a place that Redis access
# alone cannot reach, on purpose.
class BlueskyCredentials
  # The Redis hash: "handle" is plain text and "app_password" is encrypted.
  REDIS_KEY = "bluesky:credentials".freeze

  Credentials = Data.define(:handle, :app_password) do
    # @return [Boolean] True if both values are available.
    def usable? = handle.present? && app_password.present?
  end

  # The credentials for the session.
  # @return [Credentials] Its members are nil when the store has no credentials.
  def self.fetch
    stored = $redis.hgetall(REDIS_KEY) || {}
    Credentials.new(handle: stored["handle"].presence, app_password: decrypt(stored["app_password"]))
  end

  # @return [Boolean] True if the owner entered a correct pair in the admin.
  def self.stored? = fetch.usable?

  # Replaces the stored pair. A caller must check the pair first: no code here tests that the
  # credentials open a session.
  # @param handle [String]
  # @param app_password [String]
  # @return [void]
  def self.store(handle:, app_password:)
    $redis.hset(REDIS_KEY, "handle", handle.to_s.strip, "app_password", encryptor.encrypt_and_sign(app_password.to_s))
    nil
  end

  # Removes the stored pair. The integration then does nothing until the owner enters a new pair.
  # @return [void]
  def self.clear
    $redis.del(REDIS_KEY)
    nil
  end

  # ⚠️ This returns nil and does not raise when the code cannot read the message. A new
  # RAILS_MASTER_KEY must give "not connected", which the owner corrects with new credentials in
  # the admin. It must not give an exception on each page that shows the status.
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
