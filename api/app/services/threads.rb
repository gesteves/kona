require "httparty"
require "uri"

# Connects a Threads account with the OAuth2 authorization code flow, keeps its token alive, and
# posts to it.
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

  # ⚠️ `threads_basic` is the minimum, and each Threads endpoint needs it.
  # `threads_content_publish` is what `#post!` needs. The Meta dashboard must also permit each scope
  # in this list, and a change here needs a new authorization by the owner.
  SCOPES = "threads_basic,threads_content_publish".freeze

  # The limit of the text of a post. Meta counts characters, and the body of a draft is at most 300,
  # thus a post always fits and this class needs no check.
  MAX_CHARACTERS = 500

  # How long the id of a media container stays in Redis. ⚠️ Meta expires a container after 24 hours,
  # thus a value above that would name a container that is gone.
  CONTAINER_TTL = 20 * 60 * 60

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

  # Publishes one post, in the two steps that Meta needs: it makes a media container, then it
  # publishes that container.
  #
  # ⚠️ **The URL is a `link_attachment` and it is NOT in the text**, thus Meta renders its own
  # preview card and the URL uses none of the 500 characters. Mastodon is the opposite, and puts the
  # link in the text.
  #
  # ⚠️ **`idempotency_key` is what makes a retry safe, and Meta gives no header for that.** The code
  # keeps the id of the container in Redis below that key. Thus a second attempt publishes the
  # container that it made already, and it does not make a second post. Without this, a failure
  # between the two steps would leave one new container at each attempt.
  #
  # @param text [String] The body of the post.
  # @param url [String, nil] The link to attach.
  # @param idempotency_key [String] A value that is the same for each attempt.
  # @return [String] The id of the post that Meta made.
  # @raise [RuntimeError] It raises at each failure, thus the job does the work again.
  def post!(text:, url: nil, idempotency_key:)
    raise "Threads is not connected" unless connected?
    raise "The post is empty" if text.to_s.strip.blank?

    container_id = container_for(text: text, url: url, key: idempotency_key)
    published = publish_container(container_id)

    # ⚠️ It forgets the container only after Meta published it. To forget it earlier would let a
    # retry make a second post.
    $redis.del(container_key(idempotency_key))
    published
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

  # The Redis key that holds the container of one attempt.
  # @return [String]
  def container_key(key) = "threads:container:#{key}"

  # Gets the container that a previous attempt made, or makes one.
  # @return [String] The container id.
  def container_for(text:, url:, key:)
    stored = $redis.get(container_key(key))
    return stored if stored.present?

    container_id = create_container(text: text, url: url)
    $redis.set(container_key(key), container_id, ex: CONTAINER_TTL)
    container_id
  end

  # Makes a TEXT media container.
  # @return [String] The container id.
  def create_container(text:, url:)
    body = { media_type: "TEXT", text: text }
    body[:link_attachment] = url if url.present?

    response = HTTParty.post("#{API_URL}/#{@credentials.user_id}/threads",
                             body: body, query: { access_token: @credentials.access_token })
    raise "Threads refused the container: #{error_message(response)}" unless response.success?

    id = parse_json(response)&.dig(:id)
    raise "Threads gave no container id" if id.blank?

    id
  end

  # Publishes a container.
  #
  # ⚠️ Meta asks a caller to wait approximately 30 seconds before it publishes, to give its servers
  # time to process an **upload**. A TEXT post uploads nothing, thus this publishes at once. If Meta
  # refuses because the container is not ready, this raises and the retry of Sidekiq is the wait.
  # The container id stays in Redis, thus that retry publishes the same container.
  # @return [String] The id of the post.
  def publish_container(container_id)
    response = HTTParty.post("#{API_URL}/#{@credentials.user_id}/threads_publish",
                             body: { creation_id: container_id },
                             query: { access_token: @credentials.access_token })
    raise "Threads refused to publish: #{error_message(response)}" unless response.success?

    id = parse_json(response)&.dig(:id)
    raise "Threads gave no post id" if id.blank?

    id
  end

  # ⚠️ It parses the body itself and does not use `parse_json`. That helper returns nil for a
  # response that failed **and** reports an upstream error, and this method already runs inside one.
  # @param response [HTTParty::Response]
  # @return [String] The message of Meta, or the status when there is none.
  def error_message(response)
    JSON.parse(response.body.to_s, symbolize_names: true).dig(:error, :message).presence ||
      "HTTP #{response.code}"
  rescue StandardError
    "HTTP #{response.code}"
  end
end
