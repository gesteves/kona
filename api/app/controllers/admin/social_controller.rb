module Admin
  # The Social media page: the owner pastes a link, drafts one body, and the action adds one post job
  # for each network that they ticked.
  #
  # ⚠️ There is one job for each network, and not one job for all of them. Thus a failure at one
  # service retries that service alone, and a network that already posted is never sent again.
  class SocialController < BaseController
    # Each network that this page can post to, in the order of the page. `:job` posts to it, and
    # `:status` names the private method below that reads its state from Redis. ⚠️ This is the one
    # list: a network that is not here cannot take a post.
    NETWORKS = {
      "bluesky"  => { job: BlueskyPostJob,  status: :bluesky_status },
      "mastodon" => { job: MastodonPostJob, status: :mastodon_status },
      "threads"  => { job: ThreadsPostJob,  status: :threads_status }
    }.freeze

    # The most Bluesky handles that one draft asks the PDS about, and the seconds that all of those
    # calls together can take. ⚠️ Refer to #bluesky_handle_error: the budget, and not the timeout of
    # one call, is what keeps this check away from the 20-second rack-timeout.
    MAX_HANDLE_CHECKS = 8
    HANDLE_CHECK_BUDGET = 8

    # The shape of the two schedule fields, as the browser sends them. ⚠️ `Time.zone.parse` reads
    # "garbage 09:00" as today at 09:00, thus the action must match the shape before it parses.
    DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
    TIME_PATTERN = /\A\d{2}:\d{2}(:\d{2})?\z/

    # GET /social
    #
    # ⚠️ The page renders with no account connected, and each row is then disabled. It is a draft
    # screen, thus it must be available to look at and to change before an account exists.
    def show
      @social = presenter
    end

    # POST /social
    #
    # It checks the draft, then adds the jobs. ⚠️ It makes the record key **here** and gives it to
    # each job. `Bluesky#post!` writes with `putRecord` at that key, thus a Sidekiq retry replaces
    # the same post and does not add a second one.
    def create
      error = validation_error

      # ⚠️ It renders again and does not redirect. A redirect would lose the words that the owner
      # wrote, and the draft is the expensive part of this page.
      if error
        @social = presenter(posts: posts, mentions: mention_rows, selected: selected_networks,
                            scheduled: scheduled?, date: params[:date], time: params[:time])
        flash.now[:alert] = error
        return render :show, status: :unprocessable_content
      end

      # ⚠️ One key for each POST, made ONE time and OUTSIDE the loop below. The three networks get
      # a different TEXT now, because a mention reads differently at each one, and they must still
      # share one key for each post: Bluesky writes at that record key, Mastodon sends it as its
      # Idempotency-Key, and Threads keeps its media container below it. Each attempt of each job
      # carries the key of its own post, and that is what makes a retry safe.
      keys = posts.map { Bluesky.new_tid }
      at = scheduled_at

      # ⚠️ Only the FIRST post of each network is scheduled. That job adds the job of the post below
      # it when it succeeds, thus the rest of a thread goes out with it and needs no time of its own.
      selected_networks.each do |network|
        payload = posts.each_with_index.map do |post, index|
          { "key" => keys[index], "text" => text_for(network, post[:text]), "link" => post[:link] }
        end

        job = NETWORKS.fetch(network)[:job]
        at ? job.perform_at(at, payload) : job.perform_async(payload)
      end

      redirect_to social_path, status: :see_other, notice: queued_notice(at)
    end

    # GET /social/preview
    #
    # The card of a link, as JSON, for the preview on the page. ⚠️ The browser cannot read another
    # site by itself: the CSP of the admin has `connect-src :self`, and another host sends no CORS
    # header. Thus this app reads it.
    #
    # `OpenGraph#fetch` caches for 15 minutes, thus a preview also warms the cache that the post
    # job reads a moment later.
    def preview
      url = params[:url].to_s.strip
      return render json: { error: t("admin.social.errors.not_a_link") }, status: :unprocessable_content unless
        OpenGraph.http_url?(url)

      card = OpenGraph.new.fetch(url)
      render json: {
        url: card.url,
        title: card.title,
        description: card.description,
        host: host_of(card.url),
        # ⚠️ The path of our own proxy, and never the og:image itself. Refer to #preview_image.
        image_path: (social_preview_image_path(url: url) if card.image_url.present?),
        standard_site: card.document_uri.present?
      }
    end

    # GET /social/preview/image
    #
    # Proxies the picture of a card.
    #
    # ⚠️ **The browser cannot load the og:image directly**: the CSP of the admin has
    # `img-src :self`. Thus this action reads it and sends it from this host, exactly as the Course
    # maps page does for a Mapbox render.
    #
    # ⚠️ The parameter is the URL of the **page**, and not of the picture. Thus a caller cannot name
    # any URL for this app to get: the picture is always the one that the og: tags of that page
    # name. `Bluesky#card_image` then gives the **same bytes that go up as the blob**, thus the
    # preview shows what the card will hold and not the original file.
    def preview_image
      url = params[:url].to_s.strip
      return head :unprocessable_content unless OpenGraph.http_url?(url)

      image_url = OpenGraph.new.fetch(url).image_url
      return head :not_found if image_url.blank?

      picture = Bluesky.new.card_image(image_url)
      return head :not_found if picture.nil?

      send_data picture[:body], type: picture[:content_type], disposition: "inline"
    end

    private

    # @param url [String, nil]
    # @return [String, nil] The host of a URL, for the line below the title of the preview.
    def host_of(url)
      URI.parse(url.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    # The networks that this page can post to, in a stable order.
    #
    # ⚠️ Each answer comes from Redis, and no service makes an HTTP request.
    # `StandardSite#connected?` has that same rule, and its comment gives the reason: an upstream
    # failure must not go into the path of a page load.
    # @return [Array<SocialPresenter::Network>]
    def social_networks
      @social_networks ||= NETWORKS.map do |key, network|
        connected, account, notice = send(network[:status])
        SocialPresenter::Network.new(key: key, name: network_name(key), connected: connected,
                                    account: account, notice: notice)
      end
    end

    # Each `*_status` method gives `[connected, account, notice]`: whether the row can take a post,
    # the name of the account, and the reason for a row that cannot. A nil notice gives the default
    # "Not connected." of the view.
    # @return [Array]
    def bluesky_status
      service = StandardSite.new
      [ service.connected?, ("@#{service.handle}" if service.handle.present?), nil ]
    end

    # @return [Array]
    def mastodon_status
      service = Mastodon.new
      [ service.connected?, service.handle, nil ]
    end

    # ⚠️ A Threads account with an expired token is connected and cannot post: `usable?` is the
    # check, and not `connected?`. Without that the job would raise for 24 hours.
    # @return [Array]
    def threads_status
      service = Threads.new
      notice = t("admin.social.status.threads_expired") if service.expired?
      [ service.usable?, ("@#{service.username}" if service.username.present?), notice ]
    end

    # @return [SocialPresenter]
    def presenter(**overrides)
      SocialPresenter.new(networks: social_networks, **overrides)
    end

    # The networks that the owner ticked, that this app can post to, **and that have an account**.
    #
    # ⚠️ The connected check is here and not in the view alone. A row with no account renders
    # `disabled`, thus a browser cannot tick it, but a request that a person writes by hand can.
    # Without this, the job would raise "not connected" and retry for 24 hours.
    # @return [Array<String>]
    def selected_networks
      @selected_networks ||= begin
        ticked = Array(params[:networks]).map(&:to_s)
        connected = social_networks.select(&:connected?).map(&:key)
        ticked & connected & NETWORKS.keys
      end
    end

    # Each post of the thread, in order.
    #
    # ⚠️ The form sends `posts[][text]` and `posts[][link]`, and Rails starts a new hash when a key
    # repeats. Thus **both fields must render for every block, in the same order**, or each pair
    # after a block that omits one moves by one.
    #
    # ⚠️ Each field is stripped one time, here, thus the count, the limit, and the three services
    # all read the same text. Without that, a body with a newline at its end went to Bluesky as it
    # was and to Mastodon with the newline removed.
    #
    # A block with nothing at all in it is dropped: an empty block that the owner added and left
    # alone must not refuse the whole draft.
    # @return [Array<Hash>] `[{ text:, link: }, …]`
    def posts
      # ⚠️ A block that is not a hash is not a block, for the reason that #mention_rows gives.
      @posts ||= Array(params[:posts])
                 .select { |post| post.is_a?(ActionController::Parameters) || post.is_a?(Hash) }
                 .map { |post| { text: post[:text].to_s.strip, link: post[:link].to_s.strip } }
                 .reject { |post| post[:text].blank? && post[:link].blank? }
    end

    # The mention map of this draft, as the form sent it.
    #
    # ⚠️ The map is THREAD-LEVEL: there is one map for every post, because a token in post 1 and in
    # post 3 is the same person.
    #
    # ⚠️ The form sends `mentions[][token]` and one field for each key of NETWORKS. Rails starts a
    # new hash when a key repeats, thus all of those fields must render for every row, in the same
    # order. It is the rule of `posts[][text]`. A row with no token is dropped.
    # @return [Array<Hash>] `[{ token:, values: { "bluesky" => … } }, …]`, in the order of the form.
    def mention_rows
      @mention_rows ||= Array(params[:mentions]).filter_map do |row|
        # ⚠️ A row that is not a hash is not a row. A form with no row at all sends an empty
        # `mentions[]`, which arrives as a string, and a request that a person writes by hand can
        # send anything. Without this guard both give a 500.
        next unless row.is_a?(ActionController::Parameters) || row.is_a?(Hash)

        token = row[:token].to_s.strip
        next if token.blank?

        { token: token, values: NETWORKS.keys.to_h { |key| [ key, row[key].to_s.strip ] } }
      end
    end

    # The field of one network, by mention key.
    #
    # ⚠️ A blank field is absent from this hash, thus SocialMentions reads it as "this person has no
    # name here" and removes the "@" of the token. That is the fallback, and it is not a mistake.
    # @param network [String]
    # @return [Hash{String => String}]
    def values_for(network)
      @values_for ||= {}
      @values_for[network] ||= mention_rows.each_with_object({}) do |row, map|
        value = row[:values][network]
        map[SocialMentions.key(row[:token])] = value if value.present?
      end
    end

    # The text of one post, as that network will get it.
    #
    # ⚠️ **The server finds each token itself, and it reads the map as a lookup only.** It never
    # trusts the rows that the browser sent. Thus a token with no row still loses its "@", and a
    # submit with no `mentions` at all turns every mention into a plain name. That is the safe
    # direction: such a post says a name, and it can never tag a stranger.
    # @param network [String]
    # @param text [String]
    # @return [String]
    def text_for(network, text)
      SocialMentions.substitute(text, values: values_for(network), network: network)
    end

    # @return [String, nil] The reason to refuse, or nil when the draft is good.
    def validation_error
      return t("admin.social.errors.empty") if posts.empty?
      if posts.length > SocialPresenter::MAX_POSTS
        return t("admin.social.errors.too_many_posts", count: SocialPresenter::MAX_POSTS)
      end

      posts.each_with_index do |post, index|
        message = post_error(post, index)
        return message if message
      end

      return t("admin.social.errors.no_network") if selected_networks.empty?

      message = mention_shape_error
      return message if message

      # ⚠️ The handle check is LAST, because it is the one step here that calls another service.
      schedule_error || bluesky_handle_error
    end

    # ⚠️ A message names the post, because a thread has more than one and a plain message does not
    # say which one is wrong.
    # @param post [Hash]
    # @param index [Integer]
    # @return [String, nil]
    def post_error(post, index)
      # ⚠️ Every post needs words. Each of the three networks refuses a body that is empty, thus a
      # link with no words is not a post.
      return post_message("text_missing", index) if post[:text].blank?

      # ⚠️ It counts the text that BLUESKY will get, and not the words that the owner can see: a
      # mention grows into a handle, thus "@tony" can become "@tony.bsky.social". A count of the raw
      # words would pass a draft that Bluesky then refuses. The message says what it counted.
      # ⚠️ It counts the Bluesky text even when Bluesky is not ticked. 300 is the limit of this page,
      # and this check runs before #selected_networks.
      counted = text_for("bluesky", post[:text])
      unless Bluesky.valid_post_length?(counted)
        key = counted == post[:text] ? "too_long" : "too_long_handles"
        return post_message(key, index, count: Bluesky.post_length(counted),
                                        limit: Bluesky::MAX_GRAPHEMES)
      end

      message = network_length_error(post, index)
      return message if message

      # ⚠️ The link is optional. It is only refused when it is there and it is not http or https.
      return post_message("bad_link", index) if post[:link].present? && !OpenGraph.http_url?(post[:link])

      nil
    end

    # One message about one post.
    #
    # ⚠️ Each form is a COMPLETE sentence in the locale file, and this method selects one. It does
    # not join a label to a fragment: a draft of one post says "That post", and a thread names the
    # post by its number.
    # @param key [String] The name of the message below `admin.social.errors`.
    # @param index [Integer] The index of the post, counted from zero.
    # @param options [Hash] Each interpolation that the message needs.
    # @return [String]
    def post_message(key, index, **options)
      form = posts.one? ? "single" : "numbered"
      t("admin.social.errors.#{key}.#{form}", index: index + 1, **options)
    end

    # Refuses a field that holds the handle of a DIFFERENT network.
    #
    # ⚠️ Without this such a value is mangled with no message: a Mastodon handle is not a Bluesky
    # domain, thus it becomes plain words and every "@" comes out of the middle of it.
    #
    # ⚠️ It reads the ticked networks only. A field of a network that this draft does not post to
    # changes nothing, and a refusal for one would stop a draft that is correct.
    #
    # ⚠️ Plain words are never a mistake here. `SocialMentions::DIAGNOSTIC_SHAPES` holds Bluesky and
    # Mastodon alone, thus a name in any field passes. Refer to the ⚠️ on that constant.
    # @return [String, nil]
    def mention_shape_error
      mention_rows.each do |row|
        selected_networks.each do |network|
          other = SocialMentions.mistaken_network(row[:values][network], network: network)
          next if other.nil?

          return t("admin.social.errors.mistaken_network", network: network_name(network),
                                                            token: row[:token],
                                                            other: network_name(other))
        end
      end

      nil
    end

    # @param key [String] A network key.
    # @return [String] The name of that network, for a message.
    def network_name(key) = t("admin.networks.#{key}")

    # Checks the text of the other two networks against their own limits.    # Checks the text of the other two networks against their own limits.
    #
    # ⚠️ Bluesky has the shortest limit, thus the check above nearly always refuses a long draft
    # first. But a mention makes the text of each network a DIFFERENT length, and a plain name can
    # be much longer than a handle. Without this check such a draft raises in the job, which then
    # retries for 24 hours and posts nothing.
    # @param post [Hash]
    # @param index [Integer]
    # @return [String, nil]
    def network_length_error(post, index)
      # Mastodon counts a URL as URL_WEIGHT, whatever its true length, and #post! joins it with two
      # newlines.
      mastodon = text_for("mastodon", post[:text]).length +
                 (post[:link].present? ? Mastodon::URL_WEIGHT + 2 : 0)
      return post_message("too_long_mastodon", index) if mastodon > Mastodon::DEFAULT_MAX_CHARACTERS
      return nil unless text_for("threads", post[:text]).length > Threads::MAX_CHARACTERS

      post_message("too_long_threads", index)
    end

    # Asks Bluesky about each handle of the map, and refuses a draft that names one that the PDS
    # does not know. Without this, `Bluesky#mention_facets` drops that handle with no message and
    # the post shows it as plain text.
    #
    # ⚠️ It runs only for a value that has the SHAPE of a Bluesky handle. Plain words are the answer
    # for a person with no Bluesky account, and they are not a mistake.
    #
    # ⚠️ **The BUDGET is what makes this fail open, and not the timeout of one call.** Several slow
    # calls together pass the 20-second rack-timeout, and `Rack::Timeout::RequestTimeoutException`
    # is not a StandardError. Thus no rescue here would catch it, and the submit would give a 500 in
    # place of the post. `Bluesky#handle_missing?` is false for each answer but a definite refusal.
    # @return [String, nil]
    def bluesky_handle_error
      handles = bluesky_handles
      return nil if handles.empty? || handles.length > MAX_HANDLE_CHECKS

      service = Bluesky.new
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDLE_CHECK_BUDGET

      handles.each do |handle|
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        next unless service.handle_missing?(handle)

        return t("admin.social.errors.bad_handle", handle: handle)
      end

      nil
    end

    # @return [Array<String>] Each different Bluesky value of the map that is a handle and not a
    #   name. It is empty when the owner does not post to Bluesky.
    def bluesky_handles
      return [] unless selected_networks.include?("bluesky")

      values_for("bluesky").values
                           .map { |value| SocialMentions.normalize(value) }
                           .select { |value| SocialMentions.handle?(value, network: "bluesky") }
                           .uniq
    end

    # @return [Boolean] True when the owner opened the schedule fields.
    def scheduled? = ActiveModel::Type::Boolean.new.cast(params[:schedule]).present?

    # @return [String, nil] The reason to refuse the schedule, or nil.
    def schedule_error
      return nil unless scheduled?
      return t("admin.social.errors.no_moment") if picked_moment.blank?

      # ⚠️ A moment that has PASSED is not an error: it is not a schedule, thus the post goes out at
      # once. The label of the submit button says "Post now" for that same draft, and a refusal here
      # would make that button a liar.
      #
      # ⚠️ There is no limit on how far ahead this can be. The owner asked for that: a post about a
      # race can wait for the race. The job then sits in the scheduled set of Sidekiq until it runs.
      nil
    end

    # The moment that the two fields name, in the zone that the browser sent.
    #
    # ⚠️ A date and a time carry **no zone**. The browser writes its own IANA id into a hidden
    # field, thus "9:00" has one meaning. That is the difference from the Republish dialog, which
    # takes minutes from now for exactly this reason. When the Stimulus controller did not run, the
    # field is empty and `TIME_ZONE` is the fallback.
    # The moment to schedule for.
    #
    # ⚠️ It is nil for a moment that has **passed**, thus that draft takes the path of a post with
    # no schedule and goes out at once. `#picked_moment` is the raw value, and `#schedule_error`
    # reads that one to tell "no date at all" from "a date that went by".
    # @return [ActiveSupport::TimeWithZone, nil]
    def scheduled_at
      moment = picked_moment
      moment if moment && moment > Time.current
    end

    # @return [ActiveSupport::TimeWithZone, nil] The moment that the two fields name, or nil when a
    #   field is empty or has a value that cannot be read.
    def picked_moment
      return @picked_moment if defined?(@picked_moment)

      @picked_moment = parse_scheduled_at
    end

    # @return [ActiveSupport::TimeWithZone, nil]
    def parse_scheduled_at
      return nil unless scheduled?

      date = params[:date].to_s.strip
      time = params[:time].to_s.strip
      return nil unless date.match?(DATE_PATTERN) && time.match?(TIME_PATTERN)

      Time.use_zone(schedule_zone) { Time.zone.parse("#{date} #{time}") }
    rescue ArgumentError
      nil
    end

    # ⚠️ It checks the value against the zones that Rails knows. That field comes from the browser,
    # thus a value with a mistake must give the fallback and never an exception.
    # @return [String] An IANA timezone id.
    def schedule_zone
      zone = params[:time_zone].to_s.strip
      ActiveSupport::TimeZone[zone] ? zone : TimeZoneResolver.default
    end

    # @param at [ActiveSupport::TimeWithZone, nil] The moment, or nil to post now.
    # @return [String]
    def queued_notice(at)
      names = to_sentence(selected_networks)
      return t("admin.social.flash.scheduled", networks: names, at: format_schedule(at)) if at

      t("admin.social.flash.sent", networks: names)
    end

    # The moment in the words of the owner, in the zone that they picked it in. To answer in the
    # zone of the server would read as the wrong time.
    # @param at [ActiveSupport::TimeWithZone]
    # @return [String]
    def format_schedule(at)
      Time.use_zone(schedule_zone) { at.in_time_zone.strftime("%B %-e at %-I:%M %p %Z") }
    end

    # @param keys [Array<String>] Network keys.
    # @return [String] Their names, in a sentence.
    def to_sentence(keys)
      social_networks.select { |network| keys.include?(network.key) }.map(&:name).to_sentence
    end
  end
end
