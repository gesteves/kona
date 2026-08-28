# The Threads access token of the connected account, and the record of a refused refresh. Redis
# holds them, and the OAuth round trip on the Connected apps page of the admin writes them.
#
# ⚠️ The app credentials are NOT here: THREADS_APP_ID and THREADS_APP_SECRET come from the Meta
# dashboard through the environment, as the Whoop client does. This store holds the part that
# belongs to the account.
#
# This is not an ApplicationService, because that base class is for HTTP integrations and this
# class makes no network call. Threads is the class that talks to the API.
#
# ⚠️ The access token is encrypted in the store. It posts as the owner, and this Redis also holds
# the Sidekiq queues. Thus the key, which comes from secret_key_base, that is, RAILS_MASTER_KEY, is
# at a place that Redis access alone cannot reach, on purpose.
class ThreadsCredentials
  # The Redis hash. "access_token" is encrypted, and the other fields are plain text.
  REDIS_KEY = "threads:credentials".freeze

  # Meta refuses a refresh of a token that is less than 24 hours old. The margin keeps the app off
  # that limit when the clocks do not agree.
  MIN_TOKEN_AGE = 25.hours

  Credentials = Data.define(:access_token, :user_id, :username, :issued_at, :expires_at, :refresh_error) do
    # @return [Boolean] True if an account is connected now.
    def usable? = access_token.present?

    # ⚠️ Meta refuses a refresh before the token is 24 hours old. The scheduled job must count that
    # as "not yet" and never as a failure, or the card says "Needs attention" for a connection that
    # a person made minutes ago.
    # @return [Boolean] True if the token is old enough to refresh.
    def refreshable? = usable? && issued_at.present? && issued_at <= MIN_TOKEN_AGE.ago

    # ⚠️ A token that expired is dead for all time: Meta gives no method to renew one, and the
    # owner must authorize the app again.
    # @return [Boolean] True if the token passed its expiry time.
    def expired? = expires_at.present? && expires_at <= Time.current
  end

  # Everything that the flow stored.
  # @return [Credentials] Its members are nil when the store has nothing.
  def self.fetch
    stored = $redis.hgetall(REDIS_KEY) || {}

    Credentials.new(
      access_token: decrypt(stored["access_token"]),
      user_id: stored["user_id"].presence,
      username: stored["username"].presence,
      issued_at: parse_time(stored["issued_at"]),
      expires_at: parse_time(stored["expires_at"]),
      refresh_error: parse_json(stored["refresh_error"])
    )
  end

  # @return [Boolean] True if an account is connected now.
  def self.connected? = fetch.usable?

  # Stores the account at the end of the OAuth round trip.
  # @param access_token [String] The long-lived token.
  # @param expires_in [Integer] The seconds that Meta gives it.
  # @param user_id [String] The Threads id of the account.
  # @param username [String] The name to show in the admin.
  # @return [void]
  def self.store_account(access_token:, expires_in:, user_id:, username:)
    $redis.hset(REDIS_KEY, "user_id", user_id.to_s, "username", username.to_s)
    store_access_token(access_token: access_token, expires_in: expires_in)
  end

  # Stores a token, and the times that go with it. A refresh gives a new token for the same
  # account, thus this keeps the user id and the name.
  #
  # It also removes the record of a refused refresh: a token that arrives is the correction.
  # @param access_token [String]
  # @param expires_in [Integer] The seconds that Meta gives it.
  # @return [void]
  def self.store_access_token(access_token:, expires_in:)
    now = Time.current

    $redis.hset(
      REDIS_KEY,
      "access_token", encryptor.encrypt_and_sign(access_token.to_s),
      "issued_at", now.utc.iso8601,
      "expires_at", (now + expires_in.to_i.seconds).utc.iso8601
    )
    $redis.hdel(REDIS_KEY, "refresh_error")
    nil
  end

  # Records a refused refresh. Thus the Connected apps page can say that the connection needs
  # attention, and it does not show a green badge for a token that is dead.
  #
  # ⚠️ Record a 4xx only. A 5xx or a timeout means that Meta is not available, and not that the
  # token is dead. A mark for those sends the owner to authorize a connection that is good, and the
  # next scheduled run recovers by itself.
  # @param code [Integer, String] The HTTP status from the Threads token endpoint.
  # @return [void]
  def self.record_refresh_error(code)
    return unless code.to_i.between?(400, 499)

    $redis.hset(REDIS_KEY, "refresh_error", { code: code.to_i, at: Time.current.utc.iso8601 }.to_json)
    nil
  end

  # Removes the token and the account. The owner must authorize the app again to connect.
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

  # @param value [String, nil] An ISO8601 time.
  # @return [Time, nil]
  def self.parse_time(value)
    Time.iso8601(value) if value.present?
  rescue ArgumentError
    nil
  end
  private_class_method :parse_time

  # @param value [String, nil] A JSON object.
  # @return [Hash, nil]
  def self.parse_json(value)
    JSON.parse(value, symbolize_names: true) if value.present?
  rescue JSON::ParserError
    nil
  end
  private_class_method :parse_json

  # @return [ActiveSupport::MessageEncryptor]
  def self.encryptor
    @encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key("threads credentials", ActiveSupport::MessageEncryptor.key_len)
    )
  end
  private_class_method :encryptor
end
