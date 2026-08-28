# The Mastodon client registration and the access token of the connected account. Redis holds
# them, and the OAuth round trip on the Connected apps page of the admin writes them.
#
# This is not an ApplicationService, because that base class is for HTTP integrations and this
# class makes no network call. Mastodon is the class that talks to the instance.
#
# ⚠️ The client secret and the access token are encrypted in the store. The token posts as the
# owner, and this Redis also holds the Sidekiq queues. Thus the key, which comes from
# secret_key_base, that is, RAILS_MASTER_KEY, is at a place that Redis access alone cannot reach,
# on purpose.
class MastodonCredentials
  # The Redis hash. "client_secret" and "access_token" are encrypted, and the other fields are
  # plain text.
  REDIS_KEY = "mastodon:credentials".freeze

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
      "client_secret", encryptor.encrypt_and_sign(client_secret.to_s),
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
      "access_token", encryptor.encrypt_and_sign(access_token.to_s),
      "handle", handle.to_s
    )
    nil
  end

  # Removes the client and the token. The owner must name an instance again to connect.
  # @return [void]
  def self.clear
    $redis.del(REDIS_KEY)
    nil
  end

  # ⚠️ This returns nil and does not raise when the code cannot read the message. A new
  # RAILS_MASTER_KEY must give "not connected", which the owner corrects with a new connection in
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
      Rails.application.key_generator.generate_key("mastodon credentials", ActiveSupport::MessageEncryptor.key_len)
    )
  end
  private_class_method :encryptor
end
