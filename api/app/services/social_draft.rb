# One draft of the Social media page: the fields that the form sent, and the text that each network
# will get for each post.
#
# `Admin::SocialController` makes one for each request. `SocialDraftValidator` refuses a draft that
# cannot go out, `SocialPreview` shows it, and the controller adds its jobs.
# ⚠️ All three read the same object, and each value here is memoized. Thus the preview and the
# check cannot use a different text from the one that goes out.
class SocialDraft
  # The most posts in one thread. ⚠️ It is a guard against a runaway form and not a rule of any
  # network: Bluesky and Mastodon set no limit, and the limit of Threads is a rate of 250 each day.
  MAX_POSTS = 25

  # The seconds that the card reads of one request can take together. Refer to #card_for.
  CARD_READ_BUDGET = 8

  # The shape of the two schedule fields, as the browser sends them. ⚠️ `Time.zone.parse` reads
  # "garbage 09:00" as today at 09:00, thus the code must match the shape before it parses.
  DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
  TIME_PATTERN = /\A\d{2}:\d{2}(:\d{2})?\z/

  # @return [Array<SocialPresenter::Network>] Each network of the page, with its state.
  attr_reader :networks

  # @param params [ActionController::Parameters] The parameters of the request.
  # @param networks [Array<SocialPresenter::Network>] Each network of SocialNetwork, with its state. The
  #   caller reads that state from Redis, and this class makes no request for it.
  def initialize(params, networks:)
    @params = params
    @networks = networks
  end

  # The networks that the owner ticked, that this app can post to, and that have an account.
  #
  # ⚠️ The connected check is here and not in the view alone. A request that a person writes by
  # hand can tick a row with no account, and the job would then retry for 24 hours.
  # @return [Array<String>]
  def selected_networks
    @selected_networks ||= begin
      ticked = Array(@params[:networks]).map(&:to_s)
      connected = networks.select(&:connected?).map(&:key)
      ticked & connected & SocialNetwork.keys
    end
  end

  # @return [String] The names of the networks with those keys, in a sentence.
  def names_of(keys)
    networks.select { |network| keys.include?(network.key) }.map(&:name).to_sentence
  end

  # Each post of the thread, in order. A block with nothing in it is dropped.
  #
  # ⚠️ The form sends `posts[][text]` and `posts[][link]`, and Rails starts a new hash when a key
  # repeats. Thus both fields must render for every block, in the same order.
  # ⚠️ Each field is stripped one time, here, thus the count, the limit, and the three services
  # all read the same text.
  # @return [Array<Hash>] `[{ text:, link:, photos: }, …]`
  def posts
    # ⚠️ A block that is not a hash is not a block. Refer to #mention_rows.
    @posts ||= Array(@params[:posts])
               .select { |post| post.is_a?(ActionController::Parameters) || post.is_a?(Hash) }
               .map { |post| { text: post[:text].to_s.strip, link: post[:link].to_s.strip, photos: photos_of(post) } }
               .reject { |post| post[:text].blank? && post[:link].blank? && post[:photos].empty? }
  end

  # @return [Array<String>] The id of each photo of the draft.
  def photo_ids
    posts.flat_map { |post| post[:photos].map { |photo| photo[:id] } }
  end

  # The mention map of this draft, as the form sent it. A row with no token is dropped.
  #
  # ⚠️ The map is THREAD-LEVEL: a token in post 1 and in post 3 is the same person.
  # ⚠️ The form sends `mentions[][token]` and one field for each key of SocialNetwork, and all of them
  # must render for every row, in the same order. It is the rule of `posts[][text]`.
  # @return [Array<Hash>] `[{ token:, values: { "bluesky" => … } }, …]`, in the order of the form.
  def mention_rows
    @mention_rows ||= Array(@params[:mentions]).filter_map do |row|
      # ⚠️ A row that is not a hash is not a row. A form with no row sends an empty `mentions[]`,
      # which arrives as a string, and without this guard that gives a 500.
      next unless row.is_a?(ActionController::Parameters) || row.is_a?(Hash)

      token = row[:token].to_s.strip
      next if token.blank?

      { token: token, values: SocialNetwork.keys.to_h { |key| [ key, row[key].to_s.strip ] } }
    end
  end

  # The field of one network, by mention key.
  #
  # ⚠️ A blank field is absent from this hash, on purpose. SocialMentions then removes the "@" of
  # the token, because this person has no name at that network.
  # @return [Hash{String => String}]
  def values_for(network)
    @values_for ||= {}
    @values_for[network] ||= mention_rows.each_with_object({}) do |row, map|
      value = row[:values][network]
      map[SocialMentions.key(row[:token])] = value if value.present?
    end
  end

  # The Threads topic of this draft. ⚠️ It is THREAD-LEVEL, and it is not a field of a post.
  # @return [String] The topic with no "#", or an empty string.
  def topic
    @topic ||= Threads.normalize_topic(@params[:topic])
  end

  # ⚠️ It is THREAD-LEVEL: a thread goes to a network as one unit, thus one link in one post
  # decides the whole draft. `social_controller.js` uses the same rule.
  # @return [Boolean] True when the draft holds at least one Markdown link.
  def markdown?
    return @markdown if defined?(@markdown)

    @markdown = posts.any? { |post| MarkdownLinks.links?(post[:text]) }
  end

  # @return [Integer] The most photos on one post of the draft.
  def most_photos = posts.map { |post| post[:photos].length }.max.to_i

  # ⚠️ It is THREAD-LEVEL, as #markdown? is: the largest post decides the whole draft.
  # @return [Boolean] True when each post of the draft fits the photo limit of that network.
  def takes_photos?(network)
    most_photos <= SocialNetwork.find(network)&.photo_limit.to_i
  end

  # The text of one post, as that network will get it.
  #
  # ⚠️ The mentions go in first, and the typography second. A handle can hold no quotation mark and
  # no dash pair, thus the second step cannot change what the first one wrote.
  # `social_post_controller.js` counts in that order.
  # ⚠️ The typography is here, and not in `Bluesky#post!`, because each network gets it. It must
  # also run before the Markdown parse, which makes the byte offsets of each facet.
  # @return [String]
  def text_for(network, text)
    Typography.apply(mentioned(network, text))
  end

  # The text with the mentions in place, and with no typography.
  #
  # ⚠️ The server finds each token itself, and it reads the map as a lookup only. Thus a token
  # with no row loses its "@": such a post says a name, and it can never tag a stranger.
  # @return [String]
  def mentioned(network, text)
    SocialMentions.substitute(text, values: values_for(network), network: network)
  end

  # The text that Bluesky will get for one post.
  #
  # ⚠️ The link is in this text when the page gives no card, as it is at Mastodon.
  # `BlueskyPostJob` composes the same string, thus the count on the page and the post agree.
  # @param post [Hash]
  # @return [String]
  def bluesky_text(post)
    SocialText.compose(text: text_for("bluesky", post[:text]), url: bluesky_link_in_text(post))
  end

  # ⚠️ It reads a link that is http or https only. `SocialDraftValidator` refuses each other
  # scheme with a message of its own.
  # @return [String, nil] The link of a post when that link goes in the Bluesky text.
  def bluesky_link_in_text(post)
    return nil unless OpenGraph.http_url?(post[:link])

    post[:link] unless card_for(post[:link]).embeddable?
  end

  # The text that one network will receive, and each link in it.
  #
  # ⚠️ Mastodon is the one network whose text holds the link. Bluesky makes an embed of the link
  # and Threads makes an attachment.
  # ⚠️ Bluesky gets the rendered text, and one parse makes the text and the offsets. A second
  # parse for the links could mark the wrong words.
  # ⚠️ `Bluesky.link_ranges` is the rule for the three networks: it says "these words are an
  # address", and not "this network will make exactly this a link".
  # @return [Array(String, Array<MarkdownLinks::Link>)]
  def composed(network, post)
    text = text_for(network, post[:text])

    if SocialNetwork.fetch(network).markdown?
      rendered = MarkdownLinks.parse(bluesky_text(post))
      return [ rendered.text, Bluesky.link_ranges(rendered.text, rendered.links) ]
    end

    text = SocialText.compose(text: text, url: post[:link]) if SocialNetwork.fetch(network).link == :text
    [ text, Bluesky.link_ranges(text) ]
  end

  # The length of one post at one network, by the rule of that network.
  #
  # ⚠️ Each network has its own rule: Bluesky counts graphemes, Mastodon counts graphemes and a URL
  # as `URL_WEIGHT`, and Threads counts characters and an emoji as its UTF-8 bytes. This is one
  # method, thus the preview and the check cannot disagree.
  # @return [Integer]
  def length_for(network, post)
    text = text_for(network, post[:text])

    case network
    when "bluesky"  then Bluesky.post_length(bluesky_text(post))
    when "mastodon" then Mastodon.post_length(text: text, url: post[:link])
    else                 Threads.post_length(text)
    end
  end

  # @return [Integer] The most characters of one post at that network.
  def limit_of(network) = SocialNetwork.fetch(network).length_limit

  # @return [Boolean] True when a post is past the limit of that network.
  def over_limit?(network, post)
    length_for(network, post) > limit_of(network)
  end

  # The card of a page, read one time for each URL in this request. The length check, the preview
  # panel, and the card below the link field all read it.
  #
  # ⚠️ The reads of one request share CARD_READ_BUDGET. Each read is a live HTTP call, and several
  # slow ones pass the 20-second rack-timeout, which no rescue here catches. Past the budget, a
  # page gets a blank card, and the link then goes in the words.
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
  # ⚠️ The three networks get a different text, and they must share one key for each post. The
  # caller makes the keys one time and gives the same list for each network.
  # @param keys [Array<String>] One record key for each post, in order.
  # @return [Array<Hash>] `[{ "key" =>, "text" =>, "link" =>, … }, …]`
  def payload(network, keys)
    posts.each_with_index.map do |post, index|
      entry = { "key" => keys[index], "text" => text_for(network, post[:text]),
                "link" => post[:link] }
      # ⚠️ Each post of a thread carries the topic, and not the first one alone. Meta takes one
      # topic for each post, and no documentation says that a reply inherits it from its root.
      entry["topic"] = topic if SocialNetwork.fetch(network).topic? && topic.present?
      # ⚠️ The photos go only to a network that takes them. `SocialDraftValidator` already
      # refused each other network that the owner ticked.
      if SocialNetwork.fetch(network).photo_limit.positive? && post[:photos].any?
        entry["photos"] = post[:photos].map { |photo| { "id" => photo[:id], "alt" => photo[:alt] } }
      end
      entry
    end
  end

  # @return [Boolean] True when the owner opened the schedule fields.
  def scheduled? = ActiveModel::Type::Boolean.new.cast(@params[:schedule]).present?

  # The moment to schedule for.
  #
  # ⚠️ It is nil for a moment that has passed, and that draft then goes out at once.
  # `#picked_moment` is the raw value, which the validator reads.
  # @return [ActiveSupport::TimeWithZone, nil]
  def scheduled_at
    moment = picked_moment
    moment if moment && moment > Time.current
  end

  # The moment that the two fields name, in the zone that the browser sent.
  #
  # ⚠️ A date and a time carry no zone. The browser writes its own IANA id into a hidden field,
  # and `TIME_ZONE` is the fallback when that field is empty.
  # @return [ActiveSupport::TimeWithZone, nil] The moment, or nil when a field is empty or has a
  #   value that the code cannot read.
  def picked_moment
    return @picked_moment if defined?(@picked_moment)

    @picked_moment = parse_scheduled_at
  end

  # ⚠️ The field comes from the browser, thus a value that Rails does not know gives the fallback
  # and never an exception.
  # @return [String] An IANA timezone id.
  def schedule_zone
    zone = @params[:time_zone].to_s.strip
    ActiveSupport::TimeZone[zone] ? zone : TimeZoneResolver.default
  end

  private

  # The photos of one block, in order, each with its alt text.
  #
  # ⚠️ The form sends `posts[][photos][]` and `posts[][alts][]`, and the two arrays match by
  # position. Thus this pairs them first and drops a pair after that: a tile whose upload is not
  # complete sends an empty id, and the alt texts after it must not move.
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
