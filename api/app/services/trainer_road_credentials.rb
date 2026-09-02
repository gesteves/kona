# The TrainerRoad calendar URL that the workout reader gets its feed from. The owner types it on
# the Connected apps page of the admin, and Redis holds it.
#
# This is not an ApplicationService, because that base class is for HTTP integrations and this
# class makes no network call. TrainerRoad is the class that reads the feed.
#
# ⚠️ The URL is encrypted in the store (refer to EncryptedCredentials). A TrainerRoad iCal URL ends
# with a GUID, and that GUID *is* the credential: it gives the full calendar to each person who has
# the URL.
class TrainerRoadCredentials
  include EncryptedCredentials

  # The Redis hash. "calendar_url" is encrypted.
  REDIS_KEY = "trainerroad:credentials".freeze
  # ⚠️ Never change this value. Refer to EncryptedCredentials.
  ENCRYPTION_SALT = "trainerroad credentials".freeze

  # The feed that the owner connected.
  # @return [String, nil] The URL, or nil when the store has none.
  def self.fetch = decrypt($redis.hget(REDIS_KEY, "calendar_url"))

  # @return [Boolean] True if the owner connected a feed in the admin.
  def self.stored? = fetch.present?

  # Replaces the stored URL. A caller must get the feed first: no code here reads it.
  # @param calendar_url [String]
  # @return [void]
  def self.store(calendar_url:)
    $redis.hset(REDIS_KEY, "calendar_url", encrypt(calendar_url.to_s.strip))
    nil
  end
end
