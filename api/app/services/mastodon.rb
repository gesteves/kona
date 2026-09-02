require "httparty"
require "uri"

# Connects a Mastodon account with the OAuth2 authorization code flow, and posts to it.
#
# ⚠️ Mastodon has no central developer dashboard, because each instance is a separate server. Thus
# this app registers itself on the instance that the owner names (POST /api/v1/apps) and keeps the
# client that the instance gives. There is no env var for this integration, thus the Connected apps
# page always shows its card.
# @see https://docs.joinmastodon.org/methods/apps/
class Mastodon < ApplicationService
  # The name that the instance shows to the owner on its Authorized apps page.
  CLIENT_NAME = "Kona".freeze

  # ⚠️ The instance ties the scope to the token that it gives. Thus a change here needs a new
  # registration and a new authorization, and the owner must connect the account again.
  SCOPES = "read:accounts write:statuses".freeze

  # A plain hostname, with at least one dot and no port and no path.
  INSTANCE_PATTERN = /\A[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+\z/

  # Each post is public and in English. This blog has one author and one language.
  VISIBILITY = "public".freeze
  LANGUAGE = "en".freeze

  # ⚠️ Mastodon counts a URL as this many characters, whatever its true length, and the limit of a
  # default instance is 500. This class makes no length check of its own.
  # ⚠️ **The body of a draft is NOT always 300 or less.** Only the BLUESKY text carries that limit,
  # and a mention grows the text of each network by a different amount: "@tony" becomes
  # "@tony@hachyderm.io" here. Thus Admin::SocialController#post_error checks this limit against the
  # text of THIS network, before it adds the job. Without that check a long draft raises here and
  # retries for 24 hours.
  # An instance with a limit below this one would refuse the post, and the job would then run again.
  URL_WEIGHT = 23
  DEFAULT_MAX_CHARACTERS = 500

  # The seconds that each call to the instance can take. ⚠️ The registration, the token exchange,
  # and the revoke each run in a request with a 20-second rack-timeout, and the owner types the
  # hostname. A host that accepts the connection and then hangs would give a 500 in place of the
  # message of the page, and `disconnect!` would then never reach its clear.
  REQUEST_TIMEOUT = 10

  # How long the URL of a posted status stays in Redis, for a retry. ⚠️ It is longer than the
  # `retry_for` of ApplicationJob, thus each attempt of one job finds it.
  STATUS_TTL = 25.hours

  # Changes what the owner types into a bare hostname. It accepts a URL and a full handle:
  # "https://Mastodon.social/" and "@me@mastodon.social" both give "mastodon.social".
  # @param value [String, nil]
  # @return [String, nil] The hostname, or nil when the value cannot be one.
  def self.normalize_instance(value)
    host = value.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").split("/").first.to_s.split("@").last.to_s
    host if host.match?(INSTANCE_PATTERN)
  end

  # @param credentials [MastodonCredentials::Credentials] What the store holds now.
  def initialize(credentials = MastodonCredentials.fetch)
    @credentials = credentials
  end

  # @return [Boolean] True if an account is connected now. The token is the connection, because
  #   there is no database.
  def connected? = @credentials.usable?

  # @return [String, nil] The "@user@instance" name of the connected account.
  def handle = @credentials.handle

  # Registers this app on the instance and stores the client that it gives.
  # @param instance [String] A bare hostname, from .normalize_instance.
  # @param redirect_uri [String] The callback URL of this app.
  # @return [Boolean] True if the instance gave a client id and a secret.
  def register!(instance:, redirect_uri:)
    rescue_with(false, context: "Mastodon app registration") do
      client = post_json(
        "https://#{instance}/api/v1/apps",
        body: {
          client_name: CLIENT_NAME,
          redirect_uris: redirect_uri,
          scopes: SCOPES,
          website: ENV["SITE_URL"]
        },
        timeout: REQUEST_TIMEOUT
      )
      next false if client.blank? || client[:client_id].blank? || client[:client_secret].blank?

      MastodonCredentials.store_client(
        instance: instance,
        client_id: client[:client_id],
        client_secret: client[:client_secret],
        redirect_uri: redirect_uri
      )
      true
    end
  end

  # @param state [String] A value with no meaning. The callback compares it.
  # @return [String, nil] The authorization URL on the instance, or nil with no registration.
  def authorization_url(state)
    return unless @credentials.registered?

    query = {
      client_id: @credentials.client_id,
      redirect_uri: @credentials.redirect_uri,
      response_type: "code",
      scope: SCOPES,
      state: state
    }

    "https://#{@credentials.instance}/oauth/authorize?#{URI.encode_www_form(query)}"
  end

  # Changes the authorization code into an access token, and stores it with the name of the
  # account.
  #
  # ⚠️ It reads the account before it stores the token. A token that the instance gives and that
  # cannot read its own account is not a connection, and the page must not show one.
  # @param code [String] The code from the callback.
  # @return [Boolean] True if the account is connected now.
  def connect!(code)
    return false unless @credentials.registered?

    rescue_with(false, context: "Mastodon token exchange") do
      token = post_json(
        "https://#{@credentials.instance}/oauth/token",
        body: {
          grant_type: "authorization_code",
          code: code,
          client_id: @credentials.client_id,
          client_secret: @credentials.client_secret,
          redirect_uri: @credentials.redirect_uri,
          scope: SCOPES
        },
        timeout: REQUEST_TIMEOUT
      )
      access_token = token&.dig(:access_token)
      next false if access_token.blank?

      account = verify_credentials(access_token)
      next false if account.blank?

      MastodonCredentials.store_token(
        access_token: access_token,
        handle: "@#{account[:acct]}@#{@credentials.instance}"
      )
      true
    end
  end

  # Publishes one status.
  #
  # ⚠️ **The URL goes in the TEXT here, and Bluesky puts it in an embed.** Mastodon renders a link
  # inline and makes its own preview card from the og: tags of that page. Thus this class needs no
  # card and no image upload, and `Bluesky` builds both.
  #
  # ⚠️ Two things make a retry safe, and each one covers a window that the other does not.
  # `idempotency_key` goes in the `Idempotency-Key` header: the instance keeps that key for
  # approximately an hour and answers with the status that it already made. `MastodonPostJob` gives
  # the record key that the controller made before it added the job, thus each attempt sends the
  # same key. The Sidekiq retries go on for 24 hours, thus this method also keeps the URL of the
  # status in Redis below that key, and a later attempt returns it and posts nothing.
  #
  # @param text [String] The body of the post.
  # @param url [String, nil] The link to add below the body.
  # @param idempotency_key [String, nil] A value that is the same for each attempt.
  # @param in_reply_to_id [String, nil] The id of the status above this one, for a thread.
  # @return [Hash] `{ "id" =>, "url" => }`. The next post of a thread names this one with the `id`.
  # @raise [ApplicationService::HttpError, RuntimeError] It raises at each failure, thus
  #   MastodonPostJob does the work again.
  def post!(text:, url: nil, idempotency_key: nil, in_reply_to_id: nil)
    raise ApplicationJob::PermanentError, "Mastodon is not connected" unless connected?

    status = self.class.compose(text: text, url: url)
    raise ApplicationJob::PermanentError, "The post is empty" if status.blank?

    posted = posted_status(idempotency_key)
    return posted if posted.present?

    headers = { "Authorization" => "Bearer #{@credentials.access_token}" }
    headers["Idempotency-Key"] = idempotency_key if idempotency_key.present?

    body = { status: status, visibility: VISIBILITY, language: LANGUAGE }
    body[:in_reply_to_id] = in_reply_to_id if in_reply_to_id.present?

    response = post_json!(
      "https://#{@credentials.instance}/api/v1/statuses",
      body: body,
      headers: headers
    )
    # The keys are strings, thus this survives a round trip through the arguments of a Sidekiq job.
    result = {
      "id" => response&.dig(:id).presence&.to_s,
      "url" => response&.dig(:url).presence || "https://#{@credentials.instance}/"
    }
    remember_status(idempotency_key, result)
    result
  end

  # The status that this instance will receive.
  #
  # ⚠️ **The URL goes in the TEXT here**, and Bluesky makes an embed of it and Threads makes an
  # attachment. Thus this is the one network whose text holds the link.
  #
  # ⚠️ `#post!` and the preview of the Social media page both call this. Without one method the
  # preview would show a text that the post does not send.
  # @param text [String, nil] The body of the post.
  # @param url [String, nil] The link to add below the body.
  # @return [String]
  def self.compose(text:, url: nil)
    SocialText.compose(text: text, url: url)
  end

  # The length that this instance counts for a post.
  #
  # ⚠️ **Mastodon counts a URL as URL_WEIGHT, whatever its true length.** Thus this is not the
  # length of the composed status, and `String#length` on that text would give a larger number for
  # a long link.
  # @param text [String, nil]
  # @param url [String, nil]
  # @return [Integer]
  def self.post_length(text:, url: nil)
    body = text.to_s.strip
    link = url.to_s.strip
    # Graphemes, as Bluesky counts: an emoji is one character to a reader and to an instance.
    return SocialText.graphemes(body) if link.blank?

    # The two newlines that #compose writes, and then the weight of the link.
    SocialText.graphemes(body) + 2 + URL_WEIGHT
  end

  # Tells the instance to forget the token, then removes the stored credentials.
  #
  # ⚠️ The local credentials go away whether the revoke works or not. The instance can be away, or
  # the owner can have removed the app there, and a disconnect that the owner asked for must not
  # depend on that. The `ensure` is what makes that true for a rack-timeout as well: that exception
  # is not a StandardError, thus `rescue_with` does not catch it.
  # @return [void]
  def disconnect!
    revoke! if @credentials.usable?
    nil
  ensure
    MastodonCredentials.clear
  end

  private

  # @param access_token [String]
  # @return [Hash, nil] The account of the token, or nil if the instance refuses it.
  def verify_credentials(access_token)
    account = get_json(
      "https://#{@credentials.instance}/api/v1/accounts/verify_credentials",
      headers: { "Authorization" => "Bearer #{access_token}" },
      timeout: REQUEST_TIMEOUT
    )
    account if account.present? && account[:acct].present?
  end

  # @return [void]
  def revoke!
    rescue_with(context: "Mastodon token revoke") do
      HTTParty.post(
        "https://#{@credentials.instance}/oauth/revoke",
        body: {
          client_id: @credentials.client_id,
          client_secret: @credentials.client_secret,
          token: @credentials.access_token
        },
        timeout: REQUEST_TIMEOUT
      )
    end
    nil
  end

  # @param key [String, nil] The idempotency key.
  # @return [String] The Redis key that holds the status that one job posted.
  def status_key(key) = "mastodon:status:#{key}"

  # ⚠️ It keeps the **id** as well as the URL. A thread names the status above it by its id, thus a
  # second attempt of a job that already posted must give that id back and not only a URL.
  # @return [Hash, nil] What an earlier attempt of the same job posted.
  def posted_status(key)
    return if key.blank?

    raw = $redis.get(status_key(key)).presence
    return if raw.blank?

    parsed = JSON.parse(raw) rescue nil
    parsed if parsed.is_a?(Hash) && parsed["id"].present?
  end

  # @return [void]
  def remember_status(key, result)
    return if key.blank?

    $redis.set(status_key(key), result.to_json, ex: STATUS_TTL.to_i)
    nil
  end
end
