require "securerandom"

# Drives the Whoop OAuth2 authorization flow. The authorize endpoint is gated by the owner session
# so only the owner can attach an account; the callback is reachable without one — Whoop redirects
# straight to it — and is guarded instead by a one-time state validated against Redis.
#
# ⚠️ OwnerFacing for the `no-store`: the callback carries the authorization `code` and the `state`
# in its query string, so it must not be stored by a browser or an intermediary.
class WhoopOauthController < ActionController::Base
  include Authentication
  include OwnerFacing

  STATE_CACHE_KEY = "whoop:oauth:state"

  before_action :require_owner!, only: :authorize

  # Starts the flow: stores a one-time state in Redis and redirects to Whoop.
  def authorize
    url = Whoop.new.get_authorization_url(issue_state)

    if url.nil?
      render plain: "Whoop OAuth is not configured.", status: :service_unavailable
    else
      redirect_to url, allow_other_host: true
    end
  end

  # Handles Whoop's redirect: validates the state, exchanges the code for tokens.
  def callback
    if params[:error].present?
      return render plain: "Whoop authorization was denied (#{params[:error]}).", status: :bad_request
    end

    unless valid_state?(params[:state])
      return render plain: "Invalid or expired OAuth state. Start again at /whoop/auth.", status: :unprocessable_content
    end

    $redis.del(STATE_CACHE_KEY)

    if params[:code].present? && Whoop.new.exchange_code_for_tokens(params[:code])
      # Back to the page the owner started from, so the status badge reflects the new state.
      # The error branches below stay plain text: they're reachable without a session (Whoop
      # redirects here directly), and the admin layout would imply one.
      redirect_to connected_apps_path, notice: "Whoop connected."
    else
      render plain: "Failed to exchange the authorization code for tokens.", status: :bad_gateway
    end
  end

  private

  def issue_state
    state = SecureRandom.hex(16)
    $redis.setex(STATE_CACHE_KEY, 10.minutes, state)
    state
  end

  def valid_state?(state)
    expected = $redis.get(STATE_CACHE_KEY)
    state.present? && expected.present? && ActiveSupport::SecurityUtils.secure_compare(state, expected)
  end
end
