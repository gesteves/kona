# One draft of the Social media page: the fields that the form sent, and the text that each network
# will get for each post.
#
# `Admin::SocialController` makes one for each request. `SocialDraftValidator` refuses a draft that
# cannot go out, `SocialPreview` shows it, and the controller adds its jobs. ⚠️ **All three read the
# SAME object, and each value here is memoized.** Thus the preview cannot show a text that the post
# does not send, the check cannot count a different text from the one that goes out, and one
# request reads each page one time.
#
# It is not an ApplicationService, because that base class is for HTTP integrations. The one call
# to another site here is the card of a link, and `OpenGraph` makes it.
class SocialDraft
  # Each network that the page can post to, in the order of the page. `:job` posts to it.
  # ⚠️ This is the one list: a network that is not here cannot take a post. The controller needs a
  # `<key>_status` method for each key.
  # ⚠️ `limit` is here and not in the check that reads it, because the PREVIEW reads it as well.
  # In two places the page could call a draft correct and the action could then refuse it.
  NETWORKS = {
    "bluesky"  => { job: BlueskyPostJob,  limit: Bluesky::MAX_GRAPHEMES },
    "mastodon" => { job: MastodonPostJob, limit: Mastodon::DEFAULT_MAX_CHARACTERS },
    "threads"  => { job: ThreadsPostJob,  limit: Threads::MAX_CHARACTERS }
  }.freeze

  # The seconds that the card reads of one request can take together. ⚠️ Refer to #card_for. A
  # thread names as many as MAX_POSTS links, and each read of a page is a live HTTP call to another
  # site.
  CARD_READ_BUDGET = 8

  # The shape of the two schedule fields, as the browser sends them. ⚠️ `Time.zone.parse` reads
  # "garbage 09:00" as today at 09:00, thus the code must match the shape before it parses.
  DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
  TIME_PATTERN = /\A\d{2}:\d{2}(:\d{2})?\z/

  # @param key [String] A network key.
  # @return [String] The name of that network, for a message.
  def self.network_name(key) = I18n.t("admin.networks.#{key}")

  # @return [Array<SocialPresenter::Network>] Each network of the page, with its state.
  attr_reader :networks

  # @param params [ActionController::Parameters] The parameters of the request.
  # @param networks [Array<SocialPresenter::Network>] Each network of NETWORKS, with its state. The
  #   caller reads that state from Redis, and this class makes no request for it.
  def initialize(params, networks:)
    @params = params
    @networks = networks
  end

  # The networks that the owner ticked, that this app can post to, **and that have an account**.
  #
  # ⚠️ The connected check is here and not in the view alone. A row with no account renders
  # `disabled`, thus a browser cannot tick it, but a request that a person writes by hand can.
  # Without this, the job would raise "not connected" and retry for 24 hours.
  # @return [Array<String>]
  def selected_networks
    @selected_networks ||= begin
      ticked = Array(@params[:networks]).map(&:to_s)
      connected = networks.select(&:connected?).map(&:key)
      ticked & connected & NETWORKS.keys
    end
  end

  # @param keys [Array<String>] Network keys.
  # @return [String] Their names, in a sentence.
  def names_of(keys)
    networks.select { |network| keys.include?(network.key) }.map(&:name).to_sentence
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
  # @return [Array<Hash>] `[{ text:, link:, photos: }, …]`
  def posts
    # ⚠️ A block that is not a hash is not a block, for the reason that #mention_rows gives.
    @posts ||= Array(@params[:posts])
               .select { |post| post.is_a?(ActionController::Parameters) || post.is_a?(Hash) }
               .map { |post| { text: post[:text].to_s.strip, link: post[:link].to_s.strip, photos: photos_of(post) } }
               .reject { |post| post[:text].blank? && post[:link].blank? && post[:photos].empty? }
  end

  # @return [Array<String>] The id of each photo of the draft.
  def photo_ids
    posts.flat_map { |post| post[:photos].map { |photo| photo[:id] } }
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
    @mention_rows ||= Array(@params[:mentions]).filter_map do |row|
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

  # The Threads topic of this draft.
  #
  # ⚠️ It is THREAD-LEVEL, and it is not a field of a post. Meta takes one topic for each post,
  # and this one names the draft.
  # @return [String] The topic with no "#", or an empty string.
  def topic
    @topic ||= Threads.normalize_topic(@params[:topic])
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

  # @return [Integer] The most photos on one post of the draft.
  def most_photos = posts.map { |post| post[:photos].length }.max.to_i

  # ⚠️ It is THREAD-LEVEL, as #markdown? is: a thread goes to a network as one unit, thus the
  # largest post decides the whole draft. `social_controller.js` uses the same rule.
  # @param network [String] A network key.
  # @return [Boolean] True when each post of the draft fits the photo limit of that network.
  def takes_photos?(network)
    most_photos <= SocialPresenter::PHOTO_LIMITS.fetch(network, 0)
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

  # The text that Bluesky will get for one post.
  #
  # ⚠️ **The link is in this text when the page gives no card.** Bluesky renders an
  # `app.bsky.embed.external` from the og: tags, thus a page with none makes an empty box and the
  # link goes in the words instead, as it does at Mastodon. `BlueskyPostJob` composes the same
  # string, thus the count on the page and the post that goes out cannot disagree.
  # @param post [Hash]
  # @return [String]
  def bluesky_text(post)
    Bluesky.compose(text: text_for("bluesky", post[:text]), url: bluesky_link_in_text(post))
  end

  # ⚠️ It reads a link that is http or https only. A link with another scheme goes nowhere, and
  # `SocialDraftValidator` refuses it with a message of its own.
  # @param post [Hash]
  # @return [String, nil] The link of a post when that link goes in the Bluesky text.
  def bluesky_link_in_text(post)
    return nil unless OpenGraph.http_url?(post[:link])

    post[:link] unless card_for(post[:link]).embeddable?
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
  # @param network [String]
  # @param post [Hash]
  # @return [Array(String, Array<MarkdownLinks::Link>)]
  def composed(network, post)
    text = text_for(network, post[:text])

    if network == SocialPresenter::MARKDOWN_NETWORK
      rendered = MarkdownLinks.parse(bluesky_text(post))
      return [ rendered.text, Bluesky.link_ranges(rendered.text, rendered.links) ]
    end

    text = Mastodon.compose(text: text, url: post[:link]) if network == "mastodon"
    [ text, Bluesky.link_ranges(text) ]
  end

  # The length of one post at one network, by the rule of that network.
  #
  # ⚠️ Bluesky counts GRAPHEMES and the other two count characters, and Mastodon counts a URL as
  # `URL_WEIGHT` whatever its true length. This is ONE method, thus the preview and the check
  # cannot disagree about whether a draft fits.
  # @param network [String]
  # @param post [Hash]
  # @return [Integer]
  def length_for(network, post)
    text = text_for(network, post[:text])

    case network
    when "bluesky"  then Bluesky.post_length(bluesky_text(post))
    when "mastodon" then Mastodon.post_length(text: text, url: post[:link])
    else                 text.length
    end
  end

  # @param network [String]
  # @return [Integer] The most characters of one post at that network.
  def limit_of(network) = NETWORKS.fetch(network)[:limit]

  # @return [Boolean] True when a post is past the limit of that network.
  def over_limit?(network, post)
    length_for(network, post) > limit_of(network)
  end

  # The card of a page, read one time for each URL in this request.
  #
  # ⚠️ The length check, the preview panel, and the card below the link field all read it.
  # `OpenGraph` caches for 15 minutes as well, thus the check at the submit nearly always reads the
  # copy that the preview stored a moment before.
  #
  # ⚠️ **The reads of one request share CARD_READ_BUDGET.** Each read is a live HTTP call to
  # another site, and several slow reads together pass the 20-second rack-timeout, which raises
  # an exception that no rescue here catches. A 500 there loses the draft. Past the budget, a
  # page gets a blank card: the link then goes in the words, which is the same answer that the
  # job gives for a page with no tags.
  # @param url [String]
  # @return [OpenGraph::Card]
  def card_for(url)
    @card_for ||= {}
    return @card_for[url] if @card_for.key?(url)

    @card_deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + CARD_READ_BUDGET
    service = OpenGraph.new
    @card_for[url] = if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @card_deadline
      service.blank_card(url)
    else
      service.fetch(url)
    end
  end

  # The posts of the draft as the job of one network takes them.
  #
  # ⚠️ The three networks get a different TEXT, because a mention reads differently at each one,
  # and they must still share one key for each post. The caller makes the keys one time and gives
  # the same list for each network.
  # @param network [String]
  # @param keys [Array<String>] One record key for each post, in order.
  # @return [Array<Hash>] `[{ "key" =>, "text" =>, "link" =>, … }, …]`
  def payload(network, keys)
    posts.each_with_index.map do |post, index|
      entry = { "key" => keys[index], "text" => text_for(network, post[:text]),
                "link" => post[:link] }
      # ⚠️ **Each post of a thread carries the topic**, and not the first one alone. Meta takes
      # one topic for each post, and no documentation says that a reply inherits the topic of
      # its root. Thus the composer sends it with every post.
      entry["topic"] = topic if network == SocialPresenter::TOPIC_NETWORK && topic.present?
      # ⚠️ The photos go only to a network that takes them. `SocialDraftValidator` already
      # refused each other network that the owner ticked.
      if SocialPresenter::PHOTO_LIMITS.key?(network) && post[:photos].any?
        entry["photos"] = post[:photos].map { |photo| { "id" => photo[:id], "alt" => photo[:alt] } }
      end
      entry
    end
  end

  # @return [Boolean] True when the owner opened the schedule fields.
  def scheduled? = ActiveModel::Type::Boolean.new.cast(@params[:schedule]).present?

  # The moment to schedule for.
  #
  # ⚠️ It is nil for a moment that has **passed**, thus that draft takes the path of a post with
  # no schedule and goes out at once. `#picked_moment` is the raw value, and the validator reads
  # that one to tell "no date at all" from "a date that went by".
  # @return [ActiveSupport::TimeWithZone, nil]
  def scheduled_at
    moment = picked_moment
    moment if moment && moment > Time.current
  end

  # The moment that the two fields name, in the zone that the browser sent.
  #
  # ⚠️ A date and a time carry **no zone**. The browser writes its own IANA id into a hidden
  # field, thus "9:00" has one meaning. That is the difference from the Republish dialog, which
  # takes minutes from now for exactly this reason. When the Stimulus controller did not run, the
  # field is empty and `TIME_ZONE` is the fallback.
  # @return [ActiveSupport::TimeWithZone, nil] The moment, or nil when a field is empty or has a
  #   value that the code cannot read.
  def picked_moment
    return @picked_moment if defined?(@picked_moment)

    @picked_moment = parse_scheduled_at
  end

  # ⚠️ It checks the value against the zones that Rails knows. That field comes from the browser,
  # thus a value with a mistake must give the fallback and never an exception.
  # @return [String] An IANA timezone id.
  def schedule_zone
    zone = @params[:time_zone].to_s.strip
    ActiveSupport::TimeZone[zone] ? zone : TimeZoneResolver.default
  end

  private

  # The photos of one block, in order, each with its alt text.
  #
  # ⚠️ The form sends `posts[][photos][]` and `posts[][alts][]`, and the two arrays match by
  # POSITION. Thus this pairs them first and drops a pair after that: a tile whose upload is
  # still out sends an empty id, and a drop of the id alone would move each alt text after it
  # by one. An id with the wrong shape is dropped the same way.
  # @param post [ActionController::Parameters, Hash]
  # @return [Array<Hash>] `[{ id:, alt: }, …]`
  def photos_of(post)
    ids = Array(post[:photos]).map(&:to_s)
    alts = Array(post[:alts]).map(&:to_s)

    ids.each_with_index.filter_map do |id, index|
      next unless SocialPhotos.id?(id)

      { id: id, alt: alts[index].to_s.strip }
    end
  end

  # @return [ActiveSupport::TimeWithZone, nil]
  def parse_scheduled_at
    return nil unless scheduled?

    date = @params[:date].to_s.strip
    time = @params[:time].to_s.strip
    return nil unless date.match?(DATE_PATTERN) && time.match?(TIME_PATTERN)

    Time.use_zone(schedule_zone) { Time.zone.parse("#{date} #{time}") }
  rescue ArgumentError
    nil
  end
end
