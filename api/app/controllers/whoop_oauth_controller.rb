require "securerandom"

# Drives the Whoop OAuth2 authorization flow. The authorize endpoint is gated by HTTP
# Basic Auth so only the owner can attach an account; the callback is additionally
# guarded by a one-time state validated against Redis.
class WhoopOauthController < ActionController::Base
  STATE_CACHE_KEY = "whoop:oauth:state"

  before_action :authenticate_owner!, only: :authorize

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
      render plain: "Whoop connected. You can close this tab."
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

  def authenticate_owner!
    authenticate_or_request_with_http_basic("Whoop OAuth") do |username, password|
      OwnerBasicAuth.valid?(username, password)
    end
  end
end
