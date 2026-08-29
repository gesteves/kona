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

  # ⚠️ Meta needs time to process a container, and it answers `400 subcode 4279009` ("The requested
  # resource does not exist") for a publish that comes too early. Its documentation asks a caller to
  # wait approximately 30 seconds. A TEXT post uploads nothing, thus this waits for the **status**
  # in place of a flat sleep: it is usually ready at the first read.
  CONTAINER_POLL_SECONDS = 3
  CONTAINER_POLL_ATTEMPTS = 12

  # The seconds that each call to Meta can take. ⚠️ `connect!` runs in the OAuth callback, which is
  # a request with a 20-second rack-timeout. Without a limit, a Meta that hangs gives a 500 in place
  # of the message of the page.
  REQUEST_TIMEOUT = 10

  def initialize(credentials = ThreadsCredentials.fetch)
    @app_id = ENV["THREADS_APP_ID"]
    @app_secret = ENV["THREADS_APP_SECRET"]
    @credentials = credentials
  end

  # @return [Boolean] True if the Meta app credentials are available.
  def valid_credentials? = @app_id.present? && @app_secret.present?

  # @return [Boolean] True if an account is connected now. ⚠️ A connected account can hold an
  #   expired token: read `#expired?` before you post.
  def connected? = valid_credentials? && @credentials.usable?

  # ⚠️ An expired token is dead for all time, and `connected?` stays true because the token is still
  # in the store. This is the one thing that shows the difference, thus the Connected apps card and
  # the Social media page both read it.
  # @return [Boolean] True if the account is connected and its token passed its expiry time.
  def expired? = connected? && @credentials.expired?

  # @return [Boolean] True if the account can take a post now.
  def usable? = connected? && !@credentials.expired?

  # @return [Time, nil] The moment that the token expires.
  def expires_at = @credentials.expires_at

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
  #   the token is less than 24 hours old, :skipped when no account is connected, :expired when the
  #   token is dead and only a new authorization corrects that, and :failed when the call did not
  #   work.
  def refresh!
    return :skipped unless connected?
    return :expired if @credentials.expired?
    return :too_soon unless @credentials.refreshable?

    response = HTTParty.get(
      "#{GRAPH_URL}/refresh_access_token",
      query: { grant_type: "th_refresh_token", access_token: @credentials.access_token },
      timeout: REQUEST_TIMEOUT
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
  # @param reply_to_id [String, nil] The media id of the post above this one, for a thread.
  # @return [String] The id of the post that Meta made.
  # @raise [RuntimeError] It raises at each failure, thus the job does the work again.
  def post!(text:, url: nil, idempotency_key:, reply_to_id: nil)
    raise "Threads is not connected" unless connected?
    raise "The Threads token expired; connect the account again" if expired?

    text = text.to_s.strip
    raise "The post is empty" if text.blank?

    container_id = container_for(text: text, url: url, key: idempotency_key, reply_to_id: reply_to_id)
    wait_for_container(container_id)
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
      },
      timeout: REQUEST_TIMEOUT
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
      },
      timeout: REQUEST_TIMEOUT
    )
    token if token.present? && token[:access_token].present?
  end

  # ⚠️ This runs before the code stores the token. A token that cannot read its own account is not
  # a connection, and the card must not show one.
  # @return [Hash, nil] `{ id:, username: }` of the account.
  def get_profile(access_token)
    profile = get_json(
      "#{API_URL}/me",
      query: { fields: "id,username", access_token: access_token },
      timeout: REQUEST_TIMEOUT
    )
    profile if profile.present? && profile[:username].present?
  end

  # The Redis key that holds the container of one attempt.
  # @return [String]
  def container_key(key) = "threads:container:#{key}"

  # Gets the container that a previous attempt made, or makes one.
  # @return [String] The container id.
  def container_for(text:, url:, key:, reply_to_id: nil)
    stored = $redis.get(container_key(key))
    return stored if stored.present?

    container_id = create_container(text: text, url: url, reply_to_id: reply_to_id)
    $redis.set(container_key(key), container_id, ex: CONTAINER_TTL)
    container_id
  end

  # Makes a TEXT media container.
  # @return [String] The container id.
  def create_container(text:, url:, reply_to_id: nil)
    body = { media_type: "TEXT", text: text }
    body[:link_attachment] = url if url.present?
    # ⚠️ The reply goes on the CONTAINER and not on the publish. Meta reads it only here.
    # @see https://developers.facebook.com/documentation/threads/reference/publishing
    body[:reply_to_id] = reply_to_id if reply_to_id.present?

    response = HTTParty.post("#{API_URL}/#{@credentials.user_id}/threads",
                             body: body, query: { access_token: @credentials.access_token },
                             timeout: REQUEST_TIMEOUT)
    unless response.success?
      # ⚠️ It names the fields that it sent, and never their values: the text of a post is content
      # and it does not belong in an error report.
      raise "Threads refused the container (#{body.keys.join(', ')}): #{error_message(response)}"
    end

    id = parse_json(response)&.dig(:id)
    raise "Threads gave no container id" if id.blank?

    id
  end

  # Waits until Meta finished the container.
  #
  # ⚠️ **A publish that comes too early gets `400 subcode 4279009`**, and that answer reads as "The
  # requested resource does not exist", which sounds like a container that was never made. An
  # earlier version published at once, on the reasoning that a TEXT post uploads nothing. That
  # reasoning was wrong: Meta processes a TEXT container as well.
  #
  # It raises when the container never becomes ready. The id stays in Redis, thus the retry of the
  # job waits for the same container and makes no second one.
  # @param container_id [String]
  # @return [void]
  def wait_for_container(container_id)
    CONTAINER_POLL_ATTEMPTS.times do |attempt|
      case container_status(container_id)
      when "FINISHED", "PUBLISHED" then return
      when "ERROR"   then raise "Threads could not process the container #{container_id}"
      when "EXPIRED" then raise "The Threads container #{container_id} expired"
      end

      sleep CONTAINER_POLL_SECONDS unless Rails.env.test? || attempt == CONTAINER_POLL_ATTEMPTS - 1
    end

    raise "The Threads container #{container_id} is still not ready"
  end

  # @param container_id [String]
  # @return [String, nil] FINISHED, IN_PROGRESS, ERROR, EXPIRED, PUBLISHED, or nil when the read
  #   fails. A read that fails counts as "not ready" and the caller tries again.
  def container_status(container_id)
    response = HTTParty.get("#{API_URL}/#{container_id}",
                            query: { fields: "status", access_token: @credentials.access_token },
                            timeout: REQUEST_TIMEOUT)
    return unless response.success?

    parse_json(response)&.dig(:status)
  rescue StandardError
    nil
  end

  # Publishes a container.
  # @return [String] The id of the post.
  def publish_container(container_id)
    response = HTTParty.post("#{API_URL}/#{@credentials.user_id}/threads_publish",
                             body: { creation_id: container_id },
                             query: { access_token: @credentials.access_token },
                             timeout: REQUEST_TIMEOUT)
    raise "Threads refused to publish: #{error_message(response)}" unless response.success?

    id = parse_json(response)&.dig(:id)
    raise "Threads gave no post id" if id.blank?

    id
  end

  # The full error of Meta, for the log and for Bugsnag.
  #
  # ⚠️ It gives **each field** of that error, and not the message alone. The message of Meta is
  # very often "An unknown error occurred", which names no cause: the `code`, the `error_subcode`,
  # and the `fbtrace_id` are the things that a person can look up, and the trace id is the thing
  # that the support of Meta asks for.
  #
  # ⚠️ It parses the body itself and does not use `parse_json`. That helper returns nil for a
  # response that failed **and** reports an upstream error, and this method already runs inside one.
  # @param response [HTTParty::Response]
  # @return [String]
  def error_message(response)
    error = JSON.parse(response.body.to_s, symbolize_names: true)[:error] || {}
    parts = [ "HTTP #{response.code}" ]
    parts << error[:message] if error[:message].present?
    parts << "type=#{error[:type]}" if error[:type].present?
    parts << "code=#{error[:code]}" if error[:code].present?
    parts << "subcode=#{error[:error_subcode]}" if error[:error_subcode].present?
    parts << "fbtrace_id=#{error[:fbtrace_id]}" if error[:fbtrace_id].present?
    parts.join(" ")
  rescue StandardError
    "HTTP #{response.code}"
  end
end
