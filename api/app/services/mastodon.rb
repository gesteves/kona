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
  # default instance is 500. The body of a draft is at most 300, which is the Bluesky limit. Thus
  # 300 + 2 newlines + 23 is 325 and a post always fits, and this class needs no length check.
  # An instance with a limit below 325 would refuse the post, and the job would then run again.
  URL_WEIGHT = 23
  DEFAULT_MAX_CHARACTERS = 500

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
        }
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
        }
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
  # ⚠️ `idempotency_key` is what makes a retry safe. Mastodon keeps that key and answers with the
  # status that it already made, in place of a second one. `SharePostJob` gives the record key that
  # the controller made before it added the job, thus each attempt sends the same key.
  # **That window is not for ever**: the instance holds the key for a limited time, thus a retry a
  # long time later can still make a second post. It covers the attempts that follow quickly, which
  # is nearly all of them.
  #
  # @param text [String] The body of the post.
  # @param url [String, nil] The link to add below the body.
  # @param idempotency_key [String, nil] A value that is the same for each attempt.
  # @return [String] The public URL of the status.
  # @raise [ApplicationService::HttpError, RuntimeError] It raises at each failure, thus
  #   SharePostJob does the work again.
  def post!(text:, url: nil, idempotency_key: nil)
    raise "Mastodon is not connected" unless connected?

    status = [ text.to_s.strip, url.to_s.strip ].reject(&:blank?).join("\n\n")
    raise "The post is empty" if status.blank?

    headers = { "Authorization" => "Bearer #{@credentials.access_token}" }
    headers["Idempotency-Key"] = idempotency_key if idempotency_key.present?

    response = post_json!(
      "https://#{@credentials.instance}/api/v1/statuses",
      body: { status: status, visibility: VISIBILITY, language: LANGUAGE },
      headers: headers
    )
    response&.dig(:url).presence || "https://#{@credentials.instance}/"
  end

  # Tells the instance to forget the token, then removes the stored credentials.
  #
  # ⚠️ The local credentials go away whether the revoke works or not. The instance can be away, or
  # the owner can have removed the app there, and a disconnect that the owner asked for must not
  # depend on that.
  # @return [void]
  def disconnect!
    revoke! if @credentials.usable?
    MastodonCredentials.clear
    nil
  end

  private

  # @param access_token [String]
  # @return [Hash, nil] The account of the token, or nil if the instance refuses it.
  def verify_credentials(access_token)
    account = get_json(
      "https://#{@credentials.instance}/api/v1/accounts/verify_credentials",
      headers: { "Authorization" => "Bearer #{access_token}" }
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
        }
      )
    end
    nil
  end
end
