# The Strava tokens of the connected athlete, and the record of a refused refresh. Redis holds
# them, and the OAuth round trip on the Connected apps page of the admin writes them.
#
# ⚠️ The app credentials are NOT here: STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET come from the
# Strava API settings through the environment, as the Threads app credentials do.
#
# This is not an ApplicationService, because that base class is for HTTP integrations and this
# class makes no network call. Strava is the class that talks to the API.
#
# ⚠️ The two tokens are encrypted in the store (refer to EncryptedCredentials). They can edit each
# activity of the athlete.
class StravaCredentials
  include EncryptedCredentials

  # The Redis hash. "access_token" and "refresh_token" are encrypted, and the other fields are plain
  # text.
  REDIS_KEY = "strava:credentials".freeze
  # ⚠️ Never change this value. Refer to EncryptedCredentials.
  ENCRYPTION_SALT = "strava credentials".freeze

  Credentials = Data.define(:access_token, :refresh_token, :expires_at, :athlete_id, :athlete_name, :refresh_error) do
    # @return [Boolean] True if an athlete is connected now.
    def usable? = refresh_token.present?

    # @param margin [ActiveSupport::Duration] The time before the expiry that counts as expired.
    # @return [Boolean] True if the access token is absent, or expires within the margin.
    def stale?(margin) = access_token.blank? || expires_at.nil? || expires_at <= margin.from_now
  end

  # Everything that the flow stored.
  # @return [Credentials] Its members are nil when the store has nothing.
  def self.fetch
    stored = $redis.hgetall(REDIS_KEY) || {}

    Credentials.new(
      access_token: decrypt(stored["access_token"]),
      refresh_token: decrypt(stored["refresh_token"]),
      expires_at: parse_time(stored["expires_at"]),
      athlete_id: stored["athlete_id"].presence,
      athlete_name: stored["athlete_name"].presence,
      refresh_error: RefreshError.decode(stored["refresh_error"])
    )
  end

  # @return [Boolean] True if an athlete is connected now.
  def self.connected? = fetch.usable?

  # Stores the athlete at the end of the OAuth round trip.
  # @param athlete_id [String, Integer] The Strava id of the athlete.
  # @param athlete_name [String, nil] The name to show in the admin.
  # @param tokens [Hash] The token fields of the answer. Refer to .store_tokens.
  # @return [void]
  def self.store_athlete(athlete_id:, athlete_name:, **tokens)
    $redis.hset(REDIS_KEY, "athlete_id", athlete_id.to_s, "athlete_name", athlete_name.to_s)
    store_tokens(**tokens)
  end

  # Stores the tokens of an exchange or of a refresh, and removes the record of a refused refresh:
  # a token that arrives is the correction.
  #
  # ⚠️ Strava can give a NEW refresh token at each refresh, and the old one then stops working.
  # Thus each answer replaces both tokens.
  # @param access_token [String]
  # @param refresh_token [String]
  # @param expires_at [Integer] The Unix time of the expiry of the access token.
  # @return [void]
  def self.store_tokens(access_token:, refresh_token:, expires_at:)
    $redis.hset(
      REDIS_KEY,
      "access_token", encrypt(access_token),
      "refresh_token", encrypt(refresh_token),
      "expires_at", Time.at(expires_at.to_i).utc.iso8601
    )
    $redis.hdel(REDIS_KEY, "refresh_error")
    nil
  end

  # Records a refused refresh. Refer to RefreshError for the rule.
  # @param code [Integer, String] The HTTP status from the Strava token endpoint.
  # @return [void]
  def self.record_refresh_error(code)
    return unless RefreshError.refused?(code)

    $redis.hset(REDIS_KEY, "refresh_error", RefreshError.encode(code))
    nil
  end

  # @param value [String, nil] An ISO8601 time.
  # @return [Time, nil]
  def self.parse_time(value)
    Time.iso8601(value) if value.present?
  rescue ArgumentError
    nil
  end
  private_class_method :parse_time
end
