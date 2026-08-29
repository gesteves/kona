# The Bluesky handle and app password that open a PDS session. The owner types them on the
# Connected apps page of the admin, and Redis holds them.
#
# This is not an ApplicationService, because that base class is for HTTP integrations and this
# class makes no network call. StandardSite checks a credential pair, because it is the class that
# opens a session.
#
# ⚠️ The app password is encrypted in the store (refer to EncryptedCredentials). It is an account
# credential that works from each place, with no connection to one client.
class BlueskyCredentials
  include EncryptedCredentials

  # The Redis hash: "handle" is plain text and "app_password" is encrypted.
  REDIS_KEY = "bluesky:credentials".freeze
  # ⚠️ Never change this value. Refer to EncryptedCredentials.
  ENCRYPTION_SALT = "bluesky credentials".freeze

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
    $redis.hset(REDIS_KEY, "handle", handle.to_s.strip, "app_password", encrypt(app_password))
    nil
  end
end
