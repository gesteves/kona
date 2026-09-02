require "securerandom"

# The one-time `state` of an OAuth round trip. The Whoop, Mastodon, and Threads flows all use it.
#
# ⚠️ The state is in the session, and not in Redis. Thus only the browser that started the flow
# can complete it, a second flow in another browser cannot cancel the first, and the callback of
# Whoop, which the owner session does not control, still has one binding to the owner.
#
# ⚠️ The state goes away after a successful exchange only. A failed exchange keeps it, thus a
# short problem at the provider does not send the owner back to the start.
module OauthState
  extend ActiveSupport::Concern

  STATE_TTL = 10.minutes

  private

  # Makes a new state for a provider and keeps it in the session.
  # @param provider [Symbol, String] The name of the provider.
  # @return [String]
  def issue_oauth_state(provider)
    state = SecureRandom.hex(16)
    session[oauth_state_key(provider)] = { "value" => state, "expires_at" => STATE_TTL.from_now.to_i }
    state
  end

  # @param provider [Symbol, String] The name of the provider.
  # @param state [String, nil] The value that came back from the provider.
  # @return [Boolean] True when the value is the one in the session and it is not too old.
  def valid_oauth_state?(provider, state)
    stored = session[oauth_state_key(provider)]
    return false unless stored.is_a?(Hash) && state.present?

    expected = stored["value"].to_s
    return false if expected.blank? || stored["expires_at"].to_i < Time.current.to_i

    ActiveSupport::SecurityUtils.secure_compare(state, expected)
  end

  # Removes the state after a successful exchange. A replay then cannot connect again.
  # @param provider [Symbol, String] The name of the provider.
  # @return [void]
  def consume_oauth_state(provider)
    session.delete(oauth_state_key(provider))
  end

  def oauth_state_key(provider)
    "#{provider}_oauth_state"
  end
end
