# Checks one draft of the Social media page before the controller adds its jobs.
#
# ⚠️ Each check here stops a job that could never work. A post job raises for a draft that a
# network refuses, and Sidekiq then tries it again for 24 hours and posts nothing.
#
# ⚠️ The composer in the browser turns off most of what this refuses, and this is not a repeat of
# that. A control that a browser cannot use, a request that a person writes by hand can.
class SocialDraftValidator
  # The most Bluesky handles that one draft asks the PDS about, and the seconds that all of those
  # calls together can take. ⚠️ Refer to #bluesky_handle_error: the budget, and not the timeout of
  # one call, is what keeps this check away from the 20-second rack-timeout.
  MAX_HANDLE_CHECKS = 8
  HANDLE_CHECK_BUDGET = 8

  # @param draft [SocialDraft]
  def initialize(draft)
    @draft = draft
  end

  # @return [String, nil] The reason to refuse, or nil when the draft is good.
  def error
    return t("empty") if posts.empty?
    return t("too_many_posts", count: SocialPresenter::MAX_POSTS) if posts.length > SocialPresenter::MAX_POSTS

    posts.each_with_index do |post, index|
      message = post_error(post, index)
      return message if message
    end

    return t("no_network") if selected_networks.empty?

    message = markdown_network_error || photos_network_error
    return message if message

    message = topic_error
    return message if message

    message = mention_shape_error
    return message if message

    # ⚠️ The handle check is LAST, because it is the one step here that calls another service.
    schedule_error || bluesky_handle_error
  end

  private

  attr_reader :draft

  delegate :posts, :selected_networks, to: :draft, private: true

  # @param key [String] The name of a message below `admin.social.errors`.
  # @return [String]
  def t(key, **options) = I18n.t("admin.social.errors.#{key}", **options)

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
    # ⚠️ It counts the Bluesky text even when Bluesky is not ticked. 300 is the limit of the page,
    # and this check runs before the check of the ticked networks.
    # ⚠️ It counts the LINK as well, but only when that link goes in the words: a page with no
    # og: tags gets no embed. Refer to `SocialDraft#bluesky_text`. Without this the job composes a
    # longer string than this check measured, `Bluesky#post!` raises, and it retries for 24 hours.
    # #too_long_key selects the message.
    substituted = draft.mentioned("bluesky", post[:text])
    counted = draft.bluesky_text(post)
    unless Bluesky.valid_post_length?(counted)
      return post_message(too_long_key(post, substituted), index,
                          count: Bluesky.post_length(counted), limit: Bluesky::MAX_GRAPHEMES)
    end

    message = network_length_error(post, index) || photo_error(post, index)
    return message if message

    # ⚠️ The link is optional. It is only refused when it is there and it is not http or https.
    return post_message("bad_link", index) if post[:link].present? && !OpenGraph.http_url?(post[:link])

    nil
  end

  # Refuses the photos of one post that Bluesky cannot take.
  #
  # ⚠️ **A post takes photos OR a link.** Bluesky renders one embed, thus the composer disables
  # the one button while the other has a value, and this refuses a request that sends both.
  # ⚠️ A photo that is gone is one that the 24-hour draft TTL removed. Without this check the job
  # would fail the post after the owner left the page.
  # @param post [Hash]
  # @param index [Integer]
  # @return [String, nil]
  def photo_error(post, index)
    photos = post[:photos]
    return nil if photos.empty?

    return post_message("photos_and_link", index) if post[:link].present?
    if photos.length > SocialPresenter::MAX_PHOTOS
      return post_message("too_many_photos", index, limit: SocialPresenter::MAX_PHOTOS)
    end

    photos.each do |photo|
      count = SocialText.graphemes(photo[:alt])
      next if count <= SocialPresenter::ALT_LIMIT

      return post_message("alt_too_long", index, count: count, limit: SocialPresenter::ALT_LIMIT)
    end

    store = SocialPhotos.new
    return post_message("photo_missing", index) unless photos.all? { |photo| store.exists?(photo[:id]) }

    nil
  end

  # Which "that post is too long" message names the reason.
  #
  # ⚠️ **The MENTIONS and the LINK decide it, and the typography never does.** The typography runs
  # on every draft, thus a count of the finished text would say "with the Bluesky handles" for a
  # post that names nobody.
  # @param post [Hash]
  # @param substituted [String] The text with the mentions in place and no typography.
  # @return [String] The name of the message below `admin.social.errors`.
  def too_long_key(post, substituted)
    return "too_long_link" if draft.bluesky_link_in_text(post).present?

    substituted == post[:text] ? "too_long" : "too_long_handles"
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
    t("#{key}.#{form}", index: index + 1, **options)
  end

  # Checks the text of the other two networks against their own limits.
  #
  # ⚠️ Bluesky has the shortest limit, thus the check above nearly always refuses a long draft
  # first. But a mention makes the text of each network a DIFFERENT length, and a plain name can
  # be much longer than a handle. Without this check such a draft raises in the job.
  # @param post [Hash]
  # @param index [Integer]
  # @return [String, nil]
  def network_length_error(post, index)
    return post_message("too_long_mastodon", index) if draft.over_limit?("mastodon", post)
    return nil unless draft.over_limit?("threads", post)

    post_message("too_long_threads", index)
  end

  # Refuses a draft with a Markdown link that goes to a network with no rich text.
  #
  # ⚠️ Without this the post would reach a reader as `[my post](https://…)`, with the address in
  # the words.
  # @return [String, nil]
  def markdown_network_error
    return nil unless draft.markdown?

    others = selected_networks - [ SocialPresenter::MARKDOWN_NETWORK ]
    return nil if others.empty?

    t("markdown_network", networks: draft.names_of(others))
  end

  # Refuses a draft with more photos on one post than a ticked network takes.
  # @return [String, nil]
  def photos_network_error
    refused = selected_networks.reject { |network| draft.takes_photos?(network) }
    return nil if refused.empty?

    t("photos_network", networks: draft.names_of(refused))
  end

  # Refuses a topic that Meta will not take.
  #
  # ⚠️ **It reads the ticked networks only.** The field stays in the form while the Threads row is
  # not ticked, thus a value that the owner left there must not refuse a draft that goes nowhere
  # near Threads.
  #
  # ⚠️ Without this the container is refused at Meta, and `ThreadsPostJob` then retries a draft
  # that can never work.
  # @return [String, nil]
  def topic_error
    return nil unless selected_networks.include?(SocialPresenter::TOPIC_NETWORK)
    return nil if draft.topic.blank? || Threads.valid_topic?(draft.topic)

    t("bad_topic", limit: Threads::TOPIC_MAX_CHARACTERS)
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
    draft.mention_rows.each do |row|
      selected_networks.each do |network|
        other = SocialMentions.mistaken_network(row[:values][network], network: network)
        next if other.nil?

        return t("mistaken_network", network: SocialDraft.network_name(network),
                                     token: row[:token],
                                     other: SocialDraft.network_name(other))
      end
    end

    nil
  end

  # @return [String, nil] The reason to refuse the schedule, or nil.
  def schedule_error
    return nil unless draft.scheduled?
    return t("no_moment") if draft.picked_moment.blank?

    # ⚠️ A moment that has PASSED is not an error: it is not a schedule, thus the post goes out at
    # once. The label of the submit button says "Post now" for that same draft, and a refusal here
    # would make that button a liar.
    #
    # ⚠️ There is no limit on how far ahead this can be. The owner asked for that: a post about a
    # race can wait for the race. The job then sits in the scheduled set of Sidekiq until it runs.
    nil
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

      return t("bad_handle", handle: handle)
    end

    nil
  end

  # @return [Array<String>] Each different Bluesky value of the map that is a handle and not a
  #   name. It is empty when the owner does not post to Bluesky.
  def bluesky_handles
    return [] unless selected_networks.include?("bluesky")

    draft.values_for("bluesky").values
         .map { |value| SocialMentions.normalize(value) }
         .select { |value| SocialMentions.handle?(value, network: "bluesky") }
         .uniq
  end
end
