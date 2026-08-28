require "httparty"
require "uri"

# Connects a Threads account with the OAuth2 authorization code flow, and keeps its token alive.
# Nothing reads the account yet: the admin only makes the connection and shows its state.
#
# ⚠️ **A Threads token expires, and an expired one is dead for all time.** Meta gives a short-lived
# token of 1 hour, which the app changes into a long-lived token of 60 days. Only a refresh before
# that day extends it, and there is no refresh token: the token refreshes itself. Thus
# `ThreadsTokenRefreshJob` is not an improvement, and it is the thing that keeps the connection.
# @see https://developers.facebook.com/docs/threads/get-started
class Threads < ApplicationService
  AUTHORIZE_URL = "https://threads.net/oauth/authorize".freeze
  GRAPH_URL = "https://graph.threads.net".freeze
  API_URL = "https://graph.threads.net/v1.0".freeze

  # ⚠️ `threads_basic` is the minimum, and each Threads endpoint needs it. `threads_content_publish`
  # is for a later use, and nothing posts today: the app asks for it now, because a new scope needs
  # a new authorization by the owner. The Meta dashboard must also permit each scope in this list.
  SCOPES = "threads_basic,threads_content_publish".freeze

  def initialize(credentials = ThreadsCredentials.fetch)
    @app_id = ENV["THREADS_APP_ID"]
    @app_secret = ENV["THREADS_APP_SECRET"]
    @credentials = credentials
  end

  # @return [Boolean] True if the Meta app credentials are available.
  def valid_credentials? = @app_id.present? && @app_secret.present?

  # @return [Boolean] True if an account is connected now.
  def connected? = valid_credentials? && @credentials.usable?

  # @return [String, nil] The name of the connected account, with no "@".
  def username = @credentials.username

  # @return [Hash, nil] `{ code:, at: }` of the last refused refresh, or nil when the token is
  #   good.
  def refresh_error = @credentials.refresh_error

  # ⚠️ The redirect URI is not an environment variable, and the caller gives it from the request.
  # Thus it always names the admin host, which is the only host that draws the callback route. The
  # Meta dashboard must list that same URL.
  # @param state [String] A value with no meaning. The callback compares it.
  # @param redirect_uri [String] The callback URL of this app.
  # @return [String, nil] The authorization URL, or nil with no app credentials.
  def authorization_url(state, redirect_uri:)
    return unless valid_credentials?

    query = {
      client_id: @app_id,
      redirect_uri: redirect_uri,
      scope: SCOPES,
      response_type: "code",
      state: state
    }

    "#{AUTHORIZE_URL}?#{URI.encode_www_form(query)}"
  end

  # Changes the authorization code into a long-lived token, and stores it with the name of the
  # account.
  #
  # There are three calls, and each one is necessary: the code gives a token of 1 hour, the
  # exchange gives the token of 60 days, and `/me` gives the name for the admin to show.
  # @param code [String] The code from the callback.
  # @param redirect_uri [String] The same value that the authorization used.
  # @return [Boolean] True if the account is connected now.
  def connect!(code, redirect_uri:)
    return false unless valid_credentials?

    rescue_with(false, context: "Threads token exchange") do
      short_lived = exchange_code(code, redirect_uri: redirect_uri)
      next false if short_lived.blank?

      long_lived = exchange_for_long_lived_token(short_lived[:access_token])
      next false if long_lived.blank?

      profile = get_profile(long_lived[:access_token])
      next false if profile.blank?

      ThreadsCredentials.store_account(
        access_token: long_lived[:access_token],
        expires_in: long_lived[:expires_in],
        user_id: profile[:id],
        username: profile[:username]
      )
      true
    end
  end

  # Gets a new 60-day token, which replaces the one in the store. `ThreadsTokenRefreshJob` calls
  # this each day.
  #
  # @return [Symbol] :refreshed when the token is new, :too_soon when Meta would refuse it because
  #   the token is less than 24 hours old, :skipped when there is nothing to refresh, and :failed
  #   when the call did not work.
  def refresh!
    return :skipped unless connected?
    return :skipped if @credentials.expired?
    return :too_soon unless @credentials.refreshable?

    response = HTTParty.get(
      "#{GRAPH_URL}/refresh_access_token",
      query: { grant_type: "th_refresh_token", access_token: @credentials.access_token }
    )

    unless response.success?
      Rails.logger.warn("Failed to refresh the Threads token (HTTP #{response.code}).")
      report_upstream_error("HTTP #{response.code}", context: "Threads token refresh", status: response.code)
      ThreadsCredentials.record_refresh_error(response.code)
      return :failed
    end

    token = JSON.parse(response.body, symbolize_names: true)
    return :failed if token[:access_token].blank?

    ThreadsCredentials.store_access_token(access_token: token[:access_token], expires_in: token[:expires_in])
    :refreshed
  rescue StandardError => e
    Rails.logger.error("Error refreshing the Threads token: #{e}")
    report_upstream_error(e, context: "Threads token refresh")
    :failed
  end

  # Removes the stored token and the account.
  #
  # ⚠️ Meta gives no endpoint to revoke a token, thus this is a local removal only. The owner must
  # also remove the app at Threads → Settings → Website permissions to end its access there.
  # @return [void]
  def disconnect!
    ThreadsCredentials.clear
    nil
  end

  private

  # @return [Hash, nil] `{ access_token:, user_id: }` of the 1-hour token.
  def exchange_code(code, redirect_uri:)
    token = post_json(
      "#{GRAPH_URL}/oauth/access_token",
      body: {
        client_id: @app_id,
        client_secret: @app_secret,
        grant_type: "authorization_code",
        redirect_uri: redirect_uri,
        code: code
      }
    )
    token if token.present? && token[:access_token].present?
  end

  # @return [Hash, nil] `{ access_token:, expires_in: }` of the 60-day token.
  def exchange_for_long_lived_token(short_lived_token)
    token = get_json(
      "#{GRAPH_URL}/access_token",
      query: {
        grant_type: "th_exchange_token",
        client_secret: @app_secret,
        access_token: short_lived_token
      }
    )
    token if token.present? && token[:access_token].present?
  end

  # ⚠️ This runs before the code stores the token. A token that cannot read its own account is not
  # a connection, and the card must not show one.
  # @return [Hash, nil] `{ id:, username: }` of the account.
  def get_profile(access_token)
    profile = get_json(
      "#{API_URL}/me",
      query: { fields: "id,username", access_token: access_token }
    )
    profile if profile.present? && profile[:username].present?
  end
end
