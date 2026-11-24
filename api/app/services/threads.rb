require "uri"

# Connects a Threads account with the OAuth2 authorization code flow, keeps its token alive, and
# posts to it.
#
# ⚠️ A Threads token expires after 60 days, and an expired one is dead for all time. There is no
# refresh token: only a refresh before that day extends it. Thus `ThreadsTokenRefreshJob` is the
# thing that keeps the connection.
# @see https://developers.facebook.com/docs/threads/get-started
class Threads < ApplicationService
  AUTHORIZE_URL = "https://threads.net/oauth/authorize".freeze
  GRAPH_URL = "https://graph.threads.net".freeze
  API_URL = "https://graph.threads.net/v1.0".freeze

  # Each permission that the Meta dashboard of this app permits, but for `threads_trending_topics`,
  # which the owner did not enable.
  #
  # ⚠️ `threads_manage_replies` is the one that a THREAD needs: a container with a `reply_to_id` is
  # a reply. The reply guidance of Meta says that the owner of the root post needs no permission,
  # and that is not correct.
  # ⚠️ Meta answers `500` with an EMPTY body for a permission that the token does not hold, and not
  # a 403. To name the permission, GET `/{user}/threads_publishing_limit` with
  # `fields=reply_quota_usage`: it gives the same empty 500.
  # ⚠️ A change here needs a new authorization by the owner, because a token keeps the permissions
  # that made it. The owner disconnects Threads on the Connected apps page and connects it again.
  SCOPES = %w[
    threads_basic
    threads_content_publish
    threads_delete
    threads_keyword_search
    threads_location_tagging
    threads_manage_insights
    threads_manage_mentions
    threads_manage_replies
    threads_profile_discovery
    threads_read_replies
    threads_share_to_instagram
  ].join(",").freeze

  # The limit of the text of a post. Meta counts characters, and this class makes no check.
  # ⚠️ The Threads text of a draft can be longer than its Bluesky text, because a mention grows the
  # text of each network by a different amount. SocialDraftValidator#post_error checks this limit
  # before it adds the job.
  MAX_CHARACTERS = 500

  # The limit of a topic tag. ⚠️ Meta permits ONE for each post, of 1 to 50 characters, and it
  # refuses a period and an ampersand. `SocialDraftValidator#topic_error` checks a draft against
  # these before the job.
  # @see https://developers.facebook.com/documentation/threads/posts
  TOPIC_MAX_CHARACTERS = 50
  # The two characters that Meta refuses in a topic.
  TOPIC_FORBIDDEN = /[.&]/

  # @param value [String, nil] The topic as the owner wrote it.
  # @return [String] The topic with no leading "#" and no space at either end. ⚠️ The parameter of
  #   Meta takes the words alone: a "#" belongs to a tag that is IN the text, and one here would
  #   become part of the topic.
  def self.normalize_topic(value)
    value.to_s.strip.sub(/\A#+/, "").strip
  end

  # @param value [String, nil] A topic that .normalize_topic made.
  # @return [Boolean] True when Meta will take it.
  def self.valid_topic?(value)
    value = value.to_s
    value.length.between?(1, TOPIC_MAX_CHARACTERS) && !value.match?(TOPIC_FORBIDDEN)
  end

  # How long the id of a media container stays in Redis.
  # ⚠️ It is longer than the 24-hour retry window of ApplicationJob. A shorter TTL leaves the last
  # retries with no container, and each of those would make a new post.
  CONTAINER_TTL = 25 * 60 * 60
  # The time that the id of a published post stays, for a retry that comes after the publish.
  PUBLISHED_TTL = 25 * 60 * 60

  # The seconds that one token refresh holds the lock. A refresh and a reconnect at the same time
  # would each write a token, and the second write resets the issue time of the first.
  REFRESH_LOCK_TTL = 60

  # ⚠️ Meta needs time to process a container, and it answers `400 subcode 4279009` ("The requested
  # resource does not exist") for a publish that comes too early. Thus the code polls the status
  # before it publishes. A TEXT container is usually ready at the first read.
  CONTAINER_POLL_SECONDS = 3
  CONTAINER_POLL_ATTEMPTS = 12

  # The most images in one carousel. ⚠️ A carousel needs at least 2, thus one photo is an IMAGE
  # container and not a carousel.
  # @see https://developers.facebook.com/docs/threads/posts
  MAX_CAROUSEL_ITEMS = 20

  # The limit of the alt text of one image.
  # @see https://developers.facebook.com/docs/threads/reference/publishing
  MAX_ALT_TEXT_CHARACTERS = 1000

  # The seconds that each call to Meta can take. ⚠️ `connect!` runs in the OAuth callback, which
  # has a 20-second rack-timeout.
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

  # ⚠️ `connected?` stays true with an expired token, because the token is still in the store. Thus
  # the Connected apps card and the Social media page both read this.
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

  # ⚠️ The caller gives the redirect URI from the request, thus it always names the admin host,
  # which is the only host that draws the callback route. The Meta dashboard must list that URL.
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
  # account. It makes three calls: the code gives a token of 1 hour, the exchange gives the token
  # of 60 days, and `/me` gives the name for the admin to show.
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
  #   token is dead and only a new authorization corrects that, :busy when another refresh holds
  #   the lock, and :failed when the call did not work.
  def refresh!
    return :skipped unless connected?
    return :expired if @credentials.expired?
    return :too_soon unless @credentials.refreshable?
    # ⚠️ One refresh at a time. Refer to REFRESH_LOCK_TTL.
    return :busy unless $redis.set(REFRESH_LOCK_KEY, "1", nx: true, ex: REFRESH_LOCK_TTL)
    holding = true

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
    if token[:access_token].blank?
      # A 200 with no token is a failure that the Connected apps card would never show.
      report_upstream_error("Threads gave no token", context: "Threads token refresh", status: response.code)
      return :failed
    end

    ThreadsCredentials.store_access_token(access_token: token[:access_token], expires_in: token[:expires_in])
    :refreshed
  rescue StandardError => e
    Rails.logger.error("Error refreshing the Threads token: #{e}")
    report_upstream_error(e, context: "Threads token refresh")
    :failed
  ensure
    # ⚠️ Only the holder removes the lock. `holding` is nil on the :busy path, and a test on
    # `defined?(response)` is true on each path, because the parser declares that local.
    $redis.del(REFRESH_LOCK_KEY) if holding
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
  # ⚠️ The URL is a `link_attachment` and it is NOT in the text, thus Meta renders its own preview
  # card and the URL uses none of the 500 characters.
  # ⚠️ `idempotency_key` is what makes a retry safe, and Meta gives no header for that. The code
  # keeps the id of the container in Redis below that key, thus a second attempt publishes the
  # same container and makes no second post.
  #
  # @param text [String] The body of the post.
  # @param url [String, nil] The link to attach.
  # @param idempotency_key [String] A value that is the same for each attempt.
  # @param reply_to_id [String, nil] The media id of the post above this one, for a thread.
  # @param topic [String, nil] The topic tag, with no "#".
  # @param photos [Array<Hash>] `[{ url:, alt: }, …]`, MAX_CAROUSEL_ITEMS at the most. Meta GETs
  #   each URL itself, thus each one must be public.
  # @return [String] The id of the post that Meta made.
  # @raise [ApplicationJob::PermanentError] When no usable account is connected, or when the post
  #   is empty or has too many photos. The job does not run again.
  # @raise [RuntimeError] At each other failure, thus the job does the work again.
  def post!(text:, url: nil, idempotency_key:, reply_to_id: nil, topic: nil, photos: [])
    raise ApplicationJob::PermanentError, "Threads is not connected" unless connected?
    raise ApplicationJob::PermanentError, "The Threads token expired; connect the account again" if expired?
    if photos.length > MAX_CAROUSEL_ITEMS
      raise ApplicationJob::PermanentError, "Threads takes #{MAX_CAROUSEL_ITEMS} photos at the most"
    end

    text = text.to_s.strip
    raise ApplicationJob::PermanentError, "The post is empty" if text.blank? && photos.empty?

    # ⚠️ A retry can come after the publish, because Sidekiq redelivers a job whose process died
    # before the acknowledgement. The id of the published post is then the answer.
    published = $redis.get(published_key(idempotency_key))
    return published if published.present?

    container_id = container_for(text: text, url: url, key: idempotency_key,
                                 reply_to_id: reply_to_id, topic: topic, photos: photos)
    wait_for_container(container_id, key: idempotency_key)
    published = publish_container(container_id)

    # ⚠️ It remembers the post and forgets the container only after Meta published it. To forget
    # the container earlier would let a retry make a second post.
    $redis.set(published_key(idempotency_key), published, ex: PUBLISHED_TTL)
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

  REFRESH_LOCK_KEY = "threads:refresh_lock".freeze

  # @return [String] The Redis key that holds the container of one attempt.
  def container_key(key) = "threads:container:#{key}"

  # @return [String] The Redis key that holds the id of the post that an attempt published.
  def published_key(key) = "threads:published:#{key}"

  # Gets the container that a previous attempt made, or makes one.
  # @return [String] The container id.
  def container_for(text:, url:, key:, reply_to_id: nil, topic: nil, photos: [])
    stored = $redis.get(container_key(key))
    return stored if stored.present?

    container_id = create_container(text: text, url: url, reply_to_id: reply_to_id, topic: topic, photos: photos)
    $redis.set(container_key(key), container_id, ex: CONTAINER_TTL)
    container_id
  end

  # Makes the media container that gets published: TEXT with no photo, IMAGE with one, and
  # CAROUSEL with more.
  #
  # ⚠️ The text, the topic, and the reply go on THIS container, and never on a carousel item.
  # `link_attachment` is for a TEXT post only. The composer refuses photos and a link on one post.
  # @return [String] The container id.
  def create_container(text:, url:, reply_to_id: nil, topic: nil, photos: [])
    body =
      case photos.length
      when 0 then { media_type: "TEXT" }
      when 1 then image_fields(photos.first)
      else { media_type: "CAROUSEL", children: carousel_items(photos).join(",") }
      end
    body[:text] = text if text.present?
    body[:link_attachment] = url if url.present? && photos.empty?
    body[:topic_tag] = topic if topic.present?
    # ⚠️ The reply goes on the CONTAINER and not on the publish. Meta reads it only here.
    # @see https://developers.facebook.com/documentation/threads/reference/publishing
    body[:reply_to_id] = reply_to_id if reply_to_id.present?

    make_container(body)
  end

  # @param photo [Hash] `{ url:, alt: }`.
  # @return [Hash] The fields of one IMAGE container.
  def image_fields(photo)
    fields = { media_type: "IMAGE", image_url: photo[:url] }
    alt = photo[:alt].to_s.strip[0, MAX_ALT_TEXT_CHARACTERS]
    fields[:alt_text] = alt if alt.present?
    fields
  end

  # Makes one item container for each photo, and waits until Meta has processed all of them.
  # ⚠️ Meta GETs each image here. An image that it cannot get gives ERROR, and the raise names the
  # `error_message` of Meta.
  # @return [Array<String>] The item ids, in the order of the photos.
  def carousel_items(photos)
    ids = photos.map { |photo| make_container(image_fields(photo).merge(is_carousel_item: true)) }
    wait_for_containers(ids)
    ids
  end

  # POSTs one media container.
  # @param body [Hash] The fields of the container, with no token.
  # @return [String] The container id.
  def make_container(body)
    # ⚠️ The token goes in the BODY, with each other field, and not in the query string. With the
    # token in the query, a container with a `reply_to_id` answers `500` with an empty error body.
    response = HTTParty.post("#{API_URL}/#{@credentials.user_id}/threads",
                             body: body.merge(access_token: @credentials.access_token),
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

  # Waits until Meta finished one container. Refer to #wait_for_containers.
  # @param key [String] The idempotency key that holds the container.
  # @return [void]
  def wait_for_container(container_id, key:)
    wait_for_containers([ container_id ], key: key)
  end

  # Waits until Meta has finished each container of the list. It polls all of them in one loop,
  # thus ten carousel items cost one wait and not ten.
  #
  # It raises when a container never becomes ready. The id stays in Redis, thus the retry of the
  # job waits for the same container and makes no second one.
  # ⚠️ A container in the ERROR state or the EXPIRED state can never publish. The code removes its
  # id before it raises, thus the retry makes a new container and does not poll a dead one.
  # @param ids [Array<String>]
  # @param key [String, nil] The idempotency key that holds the FINAL container. ⚠️ Give nil for
  #   carousel items: an item is not below that key, and its failure must not remove the key.
  # @return [void]
  def wait_for_containers(ids, key: nil)
    pending = ids.dup
    failures = 0
    CONTAINER_POLL_ATTEMPTS.times do |attempt|
      read_failed = false
      pending = pending.reject do |container_id|
        container = container_status(container_id)
        case container&.dig(:status)
        when "FINISHED", "PUBLISHED" then true
        when "ERROR"
          $redis.del(container_key(key)) if key
          raise "Threads could not process the container #{container_id}#{error_detail(container)}"
        when "EXPIRED"
          $redis.del(container_key(key)) if key
          raise "The Threads container #{container_id} expired"
        else
          read_failed ||= container.nil?
          false
        end
      end
      return if pending.empty?

      # ⚠️ A read that fails is not "not ready". Meta that is away must not cost the full poll of
      # 33 seconds at each attempt: three failures in a row end the poll, and the retry of the
      # job is the wait.
      failures = read_failed ? failures + 1 : 0
      raise "Threads did not answer for the container #{pending.first}" if failures >= MAX_STATUS_FAILURES

      sleep CONTAINER_POLL_SECONDS unless Rails.env.test? || attempt == CONTAINER_POLL_ATTEMPTS - 1
    end

    raise "The Threads container #{pending.first} is still not ready"
  end

  # @param container [Hash] What #container_status gives.
  # @return [String] ": <message>" when Meta gave a reason, or an empty string.
  def error_detail(container)
    message = container[:error_message].presence
    message ? ": #{message}" : ""
  end

  MAX_STATUS_FAILURES = 3

  # @param container_id [String]
  # @return [Hash, nil] `{ status:, error_message: }`, where the status is FINISHED, IN_PROGRESS,
  #   ERROR, EXPIRED, or PUBLISHED. Nil when the read fails. The caller counts the failures.
  def container_status(container_id)
    response = HTTParty.get("#{API_URL}/#{container_id}",
                            query: { fields: "status,error_message", access_token: @credentials.access_token },
                            timeout: REQUEST_TIMEOUT)
    unless response.success?
      report_upstream_error("HTTP #{response.code}", context: "Threads container status", status: response.code)
      return
    end

    container = parse_json(response)
    container.slice(:status, :error_message) if container.is_a?(Hash) && container[:status].present?
  rescue StandardError => e
    report_upstream_error(e, context: "Threads container status")
    nil
  end

  # Publishes a container.
  # @return [String] The id of the post.
  def publish_container(container_id)
    response = HTTParty.post("#{API_URL}/#{@credentials.user_id}/threads_publish",
                             body: { creation_id: container_id,
                                     access_token: @credentials.access_token },
                             timeout: REQUEST_TIMEOUT)
    raise "Threads refused to publish: #{error_message(response)}" unless response.success?

    id = parse_json(response)&.dig(:id)
    raise "Threads gave no post id" if id.blank?

    id
  end

  # The full error of Meta, for the log and for Bugsnag.
  #
  # ⚠️ It gives each field of that error, and not the message alone. The message of Meta is often
  # "An unknown error occurred", and the `code`, the `error_subcode`, and the `fbtrace_id` are the
  # things that a person can look up.
  # ⚠️ It parses the body itself, because `parse_json` reports an upstream error for a response
  # that failed, and this method already runs inside one.
  # @return [String]
  def error_message(response)
    parsed = JSON.parse(response.body.to_s, symbolize_names: true)
    error = parsed.is_a?(Hash) ? parsed[:error].to_h : {}
    parts = [ "HTTP #{response.code}" ]

    # ⚠️ Meta sometimes answers 500 with NO error object at all, and the fields below are then all
    # empty. The raw body is the only thing left to read, thus it goes in the message.
    return "HTTP #{response.code} body=#{response.body.to_s[0, 300].inspect}" if error.empty?

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
