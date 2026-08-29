# The Mastodon client registration and the access token of the connected account. Redis holds
# them, and the OAuth round trip on the Connected apps page of the admin writes them.
#
# This is not an ApplicationService, because that base class is for HTTP integrations and this
# class makes no network call. Mastodon is the class that talks to the instance.
#
# ⚠️ The client secret and the access token are encrypted in the store (refer to
# EncryptedCredentials). The token posts as the owner.
class MastodonCredentials
  include EncryptedCredentials

  # The Redis hash. "client_secret" and "access_token" are encrypted, and the other fields are
  # plain text.
  REDIS_KEY = "mastodon:credentials".freeze
  # ⚠️ Never change this value. Refer to EncryptedCredentials.
  ENCRYPTION_SALT = "mastodon credentials".freeze

  Credentials = Data.define(:instance, :client_id, :client_secret, :redirect_uri, :access_token, :handle) do
    # @return [Boolean] True if the app has a client on the instance, thus it can start the flow.
    def registered? = instance.present? && client_id.present? && client_secret.present? && redirect_uri.present?

    # @return [Boolean] True if an account is connected now.
    def usable? = registered? && access_token.present?
  end

  # Everything that the flow stored.
  # @return [Credentials] Its members are nil when the store has nothing.
  def self.fetch
    stored = $redis.hgetall(REDIS_KEY) || {}

    Credentials.new(
      instance: stored["instance"].presence,
      client_id: stored["client_id"].presence,
      client_secret: decrypt(stored["client_secret"]),
      redirect_uri: stored["redirect_uri"].presence,
      access_token: decrypt(stored["access_token"]),
      handle: stored["handle"].presence
    )
  end

  # @return [Boolean] True if an account is connected now.
  def self.connected? = fetch.usable?

  # Stores the client that the instance gave, at the start of the flow.
  #
  # ⚠️ It removes the access token and the handle. Without that, an owner who names a second
  # instance keeps the token of the first one, and the page then shows "Connected" for an account
  # that the new client cannot reach.
  # @param instance [String] The bare hostname of the instance.
  # @param client_id [String]
  # @param client_secret [String]
  # @param redirect_uri [String] The callback URL that the registration named. The token exchange
  #   must send the same value.
  # @return [void]
  def self.store_client(instance:, client_id:, client_secret:, redirect_uri:)
    $redis.hdel(REDIS_KEY, "access_token", "handle")
    $redis.hset(
      REDIS_KEY,
      "instance", instance.to_s,
      "client_id", client_id.to_s,
      "client_secret", encrypt(client_secret),
      "redirect_uri", redirect_uri.to_s
    )
    nil
  end

  # Stores the access token at the end of the flow.
  # @param access_token [String]
  # @param handle [String] The "@user@instance" name of the account, for the admin to show.
  # @return [void]
  def self.store_token(access_token:, handle:)
    $redis.hset(
      REDIS_KEY,
      "access_token", encrypt(access_token),
      "handle", handle.to_s
    )
    nil
  end
end
