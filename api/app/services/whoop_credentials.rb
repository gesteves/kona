# Encrypts the Whoop tokens at rest. Whoop keeps its own Redis keys, one for each client id and
# with a TTL on the access token, thus this is not a hash store as the other credential classes
# are. It gives the two token keys the same encryption, from the same concern.
#
# This is not an ApplicationService, because it makes no network call. Whoop is the class that
# speaks to the API. `Whoop#disconnect!` removes the keys, and `clear` here is not the disconnect.
class WhoopCredentials
  include EncryptedCredentials

  # No hash holds the Whoop tokens. The concern needs a name, and `clear` deletes only this key.
  REDIS_KEY = "whoop:credentials".freeze
  # ⚠️ Never change this value. Refer to EncryptedCredentials.
  ENCRYPTION_SALT = "whoop tokens".freeze

  # @param value [String] A token.
  # @return [String] The encrypted message, for a Redis value.
  def self.seal(value) = encrypt(value)

  # @param value [String, nil] A Redis value.
  # @return [String, nil] The token, or nil when the code cannot read the message.
  def self.open(value) = decrypt(value)
end
