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
    # ⚠️ `limit` is here and not in the check that reads it, because the PREVIEW reads it as well.
    # In two places the page could call a draft correct and the action could then refuse it.
    NETWORKS = {
      "bluesky"  => { job: BlueskyPostJob,  status: :bluesky_status,
                      limit: Bluesky::MAX_GRAPHEMES },
      "mastodon" => { job: MastodonPostJob, status: :mastodon_status,
                      limit: Mastodon::DEFAULT_MAX_CHARACTERS },
      "threads"  => { job: ThreadsPostJob,  status: :threads_status,
                      limit: Threads::MAX_CHARACTERS }
    }.freeze

    # Where the link goes for a network that keeps it OUT of the text, for the note of the preview.
    # ⚠️ Mastodon is absent on purpose: its text holds the link, thus the owner can see it.
    # The network whose preview shows the LINK below the words.
    #
    # ⚠️ Bluesky is absent because the panel draws its card, and Mastodon is absent because
    # `Mastodon.compose` puts the link in the text, thus it is already a segment there. Threads
    # makes an attachment that Meta renders and this app cannot draw, thus the panel shows the
    # address itself.
    LINK_SHOWN = "threads".freeze

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
                            scheduled: scheduled?, date: params[:date], time: params[:time],
                            topic: params[:topic])
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
          entry = { "key" => keys[index], "text" => text_for(network, post[:text]),
                    "link" => post[:link] }
          # ⚠️ **Each post of a thread carries the topic**, and not the first one alone. Meta takes
          # one topic for each post, and no documentation says that a reply inherits the topic of
          # its root. Thus the composer sends it with every post.
          entry["topic"] = topic if network == SocialPresenter::TOPIC_NETWORK && topic.present?
          entry
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

      render json: card_json(url)
    end

    # POST /social/preview/text
    #
    # The draft as each connected network will receive it, as JSON.
    #
    # ⚠️ **It reads the same fields as #create and it calls the same private methods.** Thus the
    # preview cannot show a text that the post does not send, and a change to the substitution
    # reaches both. It writes nothing, it adds no job, and it calls no other service.
    #
    # ⚠️ It is a POST, and the two previews below are GET. A draft is as much as MAX_POSTS posts of
    # 300 characters and a mention map, thus a query string is the wrong shape for it.
    def preview_text
      # ⚠️ A draft with a Markdown link shows BLUESKY alone, because it can go nowhere else. To
      # render the other two would show a text that this app refuses to post. The composer turns
      # their checkboxes off by the same rule, thus the page and the dialog agree.
      networks = social_networks.select(&:connected?)
      networks = networks.select { |network| network.markdown? } if markdown?

      # ⚠️ It groups by NETWORK and not by post, thus the panel reads as the thread reads: each
      # network in turn, and its posts in the order that they go out.
      render json: {
        networks: networks.map { |network|
          { key: network.key, name: network.name,
            posts: posts.map { |post| preview_post(network, post) } }
        }
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
    # ⚠️ **The two steps are in THIS ORDER.** The mentions go in first, and the typography second:
    # a handle can hold no quotation mark and no dash pair, thus nothing that the first step writes
    # can be read as punctuation by the second. `social_post_controller.js` counts in that order.
    #
    # ⚠️ **The typography is here, and not in `Bluesky#post!`.** Each of the three networks gets it,
    # because a curly quotation mark is a character and not rich text. It must also run BEFORE the
    # Markdown parse, and that parse makes the byte offsets of each facet: a `...` that became `…`
    # after those offsets were made would move every facet after it.
    # @param network [String]
    # @param text [String]
    # @return [String]
    def text_for(network, text)
      Typography.apply(mentioned(network, text))
    end

    # The text with the mentions in place, and with no typography.
    #
    # ⚠️ **The server finds each token itself, and it reads the map as a lookup only.** It never
    # trusts the rows that the browser sent. Thus a token with no row still loses its "@", and a
    # submit with no `mentions` at all turns every mention into a plain name. That is the safe
    # direction: such a post says a name, and it can never tag a stranger.
    # @param network [String]
    # @param text [String]
    # @return [String]
    def mentioned(network, text)
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

      message = markdown_network_error
      return message if message

      message = topic_error
      return message if message

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
      # ⚠️ The MENTIONS decide which message it is, and the typography never does. The typography
      # runs on every draft, thus a count of the finished text would say "with the Bluesky handles"
      # for a post that names nobody.
      substituted = mentioned("bluesky", post[:text])
      counted = text_for("bluesky", post[:text])
      unless Bluesky.valid_post_length?(counted)
        key = substituted == post[:text] ? "too_long" : "too_long_handles"
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

    # The Threads topic of this draft.
    #
    # ⚠️ It is THREAD-LEVEL, and it is not a field of a post. Meta takes one topic for each post,
    # and this one names the draft.
    # @return [String] The topic with no "#", or an empty string.
    def topic
      @topic ||= Threads.normalize_topic(params[:topic])
    end

    # Refuses a topic that Meta will not take.
    #
    # ⚠️ **It reads the ticked networks only.** The field stays in the form while the Threads row is
    # not ticked, thus a value that the owner left there must not refuse a draft that goes nowhere
    # near Threads.
    #
    # ⚠️ Without this the container is refused at Meta, and `ThreadsPostJob` then retries a draft
    # that can never work, for 24 hours.
    # @return [String, nil]
    def topic_error
      return nil unless selected_networks.include?(SocialPresenter::TOPIC_NETWORK)
      return nil if topic.blank? || Threads.valid_topic?(topic)

      t("admin.social.errors.bad_topic", limit: Threads::TOPIC_MAX_CHARACTERS)
    end

    # @return [Boolean] True when the draft holds at least one Markdown link.
    #
    # ⚠️ It is THREAD-LEVEL: a thread goes to a network as one unit, thus one link in one post
    # decides the whole draft. `social_controller.js` turns the two checkboxes off by that same
    # rule.
    def markdown?
      return @markdown if defined?(@markdown)

      @markdown = posts.any? { |post| MarkdownLinks.links?(post[:text]) }
    end

    # Refuses a draft with a Markdown link that goes to a network with no rich text.
    #
    # ⚠️ **The composer already unticks and disables those two rows, and this is not a repeat of
    # that.** A row that a browser cannot tick, a request that a person writes by hand can. Without
    # this the post would reach a reader as `[my post](https://…)`, with the address in the words.
    # @return [String, nil]
    def markdown_network_error
      return nil unless markdown?

      others = selected_networks - [ SocialPresenter::MARKDOWN_NETWORK ]
      return nil if others.empty?

      t("admin.social.errors.markdown_network", networks: to_sentence(others))
    end

    # One post of one network, for the preview.
    # @param network [SocialPresenter::Network]
    # @param post [Hash]
    # @return [Hash]
    def preview_post(network, post)
      limit = NETWORKS.fetch(network.key)[:limit]
      length = length_for(network.key, post)
      text, links = composed(network.key, post)

      { text: text, segments: segments(text, links), length: length, limit: limit,
        over: length > limit, topic: preview_topic(network.key),
        link: preview_link(network.key, post), card: preview_card(network.key, post) }
    end

    # ⚠️ It is NOT part of the text and it uses none of the characters of that network: Threads
    # makes an attachment of it. The panel shows it below the words, because a post with a link
    # that nothing shows reads as a post with no link.
    # @return [String, nil]
    def preview_link(network, post)
      return nil unless network == LINK_SHOWN && post[:link].present?

      post[:link]
    end

    # The website card that Bluesky will render for the link of a post.
    #
    # ⚠️ **Bluesky alone**, because this app BUILDS that card: `Bluesky#build_card` makes an
    # `app.bsky.embed.external` from these same og: tags. Threads gets a `link_attachment` and Meta
    # renders a preview of its own, thus this app has nothing to show for it and the note stays.
    # @return [Hash, nil]
    def preview_card(network, post)
      return nil unless network == "bluesky" && post[:link].present?
      return nil unless OpenGraph.http_url?(post[:link])

      card_json(post[:link])
    end

    # One website card, as JSON.
    #
    # ⚠️ **`#preview` and the panel read the same method**, thus the card below a link and the card
    # in the preview cannot describe one page differently.
    #
    # ⚠️ It is memoized by URL: a thread that names one link in two posts reads that page one time.
    # `OpenGraph#fetch` also caches for 15 minutes, thus a preview warms the cache that the post job
    # reads a moment later.
    # @param url [String]
    # @return [Hash]
    def card_json(url)
      @card_json ||= {}
      @card_json[url] ||= begin
        card = OpenGraph.new.fetch(url)
        {
          url: card.url,
          title: card.title,
          description: card.description,
          host: host_of(card.url),
          # ⚠️ The path of our own proxy, and never the og:image itself. Refer to #preview_image.
          image_path: (social_preview_image_path(url: url) if card.image_url.present?),
          standard_site: card.document_uri.present?
        }
      end
    end

    # The text that one network will receive, and each link in it.
    #
    # ⚠️ **Mastodon is the one network whose text holds the LINK**, and `Mastodon.compose` is the
    # method that `Mastodon#post!` calls. Bluesky makes an embed of the link and Threads makes an
    # attachment, thus neither text holds it.
    #
    # ⚠️ **Bluesky gets the RENDERED text**, because `Bluesky#post!` renders the Markdown itself.
    # ONE parse makes the text and the offsets: a second parse for the links could answer
    # differently after an edit to the grammar, and the dialog would then mark the wrong words.
    #
    # ⚠️ `Bluesky.link_ranges` is the rule for the three networks, and not for Bluesky alone. Each
    # instance linkifies a bare URL with a rule of its own, thus this says "these words are an
    # address" and not "Mastodon will make exactly this a link". `SocialMentions` reads that same
    # pattern for the same reason.
    # @return [Array(String, Array<MarkdownLinks::Link>)]
    def composed(network, post)
      text = text_for(network, post[:text])

      if network == SocialPresenter::MARKDOWN_NETWORK
        rendered = MarkdownLinks.parse(text)
        return [ rendered.text, Bluesky.link_ranges(rendered.text, rendered.links) ]
      end

      text = Mastodon.compose(text: text, url: post[:link]) if network == "mastodon"
      [ text, Bluesky.link_ranges(text) ]
    end

    # The text in pieces, so that the dialog can render each link as a link.
    #
    # ⚠️ **A `url` is always http or https**, because `MarkdownLinks::URL_PATTERN` and
    # `Bluesky::URL_PATTERN` both start with that scheme. Thus the browser can write one into an
    # `href` with no check of its own, and no draft can make a `javascript:` link in the admin.
    # @param text [String]
    # @param links [Array<MarkdownLinks::Link>] In order, and with no overlap.
    # @return [Array<Hash>] `[{ text: }, { text:, url: }, …]`, in order and with no gap.
    def segments(text, links)
      pieces = []
      last = 0

      links.each do |link|
        pieces << { text: text[last...link.start] } if link.start > last
        pieces << { text: text[link.start...link.finish], url: link.url }
        last = link.finish
      end

      pieces << { text: text[last..] } if last < text.length
      pieces
    end

    # The length of one post at one network, by the rule of that network.
    #
    # ⚠️ Bluesky counts GRAPHEMES and the other two count characters, and Mastodon counts a URL as
    # `URL_WEIGHT` whatever its true length. This is ONE method, thus the preview and the check
    # below cannot disagree about whether a draft fits.
    # @return [Integer]
    def length_for(network, post)
      text = text_for(network, post[:text])

      case network
      when "bluesky"  then Bluesky.post_length(text)
      when "mastodon" then Mastodon.post_length(text: text, url: post[:link])
      else                 text.length
      end
    end

    # ⚠️ It is the topic ITSELF and not a sentence about it: the panel renders it as a badge above
    # the words, which is where the Threads app shows it. Each post carries it, exactly as
    # `#create` sends it.
    # @return [String, nil]
    def preview_topic(network)
      return nil unless network == SocialPresenter::TOPIC_NETWORK && topic.present?

      topic
    end

    # Checks the text of the other two networks against their own limits.
    #
    # ⚠️ Bluesky has the shortest limit, thus the check above nearly always refuses a long draft
    # first. But a mention makes the text of each network a DIFFERENT length, and a plain name can
    # be much longer than a handle. Without this check such a draft raises in the job, which then
    # retries for 24 hours and posts nothing.
    # @param post [Hash]
    # @param index [Integer]
    # @return [String, nil]
    def network_length_error(post, index)
      return post_message("too_long_mastodon", index) if over_limit?("mastodon", post)
      return nil unless over_limit?("threads", post)

      post_message("too_long_threads", index)
    end

    # @return [Boolean] True when a post is past the limit of that network.
    def over_limit?(network, post)
      length_for(network, post) > NETWORKS.fetch(network)[:limit]
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
