# Checks one draft of the Social media page before the controller adds its jobs.
#
# ⚠️ Each check here stops a job that could never work. A post job raises for a draft that a
# network refuses, and Sidekiq then tries it again for 24 hours and posts nothing.
#
# ⚠️ The composer in the browser turns off most of what this refuses, and this is not a repeat of
# that. A control that a browser cannot use, a request that a person writes by hand can.
class SocialDraftValidator
  # The most Bluesky handles that one draft asks the PDS about, and the seconds that all of those
  # calls together can take. Refer to #bluesky_handle_error.
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
  def t(key, **options) = I18n.t("admin.social.errors.#{key}", **options)

  # ⚠️ A message names the post, because a thread has more than one.
  # @return [String, nil]
  def post_error(post, index)
    # ⚠️ Every post needs words: each of the three networks refuses an empty body.
    return post_message("text_missing", index) if post[:text].blank?

    # ⚠️ It counts the text that BLUESKY will get, and not the words that the owner sees: a mention
    # grows into a handle. It does this even when Bluesky is not ticked, because 300 is the limit
    # of the page.
    # ⚠️ It counts the link as well, when that link goes in the words. Without this the job
    # composes a longer string than this check measured, and `Bluesky#post!` raises for 24 hours.
    # Refer to `SocialDraft#bluesky_text`.
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
  # ⚠️ A post takes photos OR a link, because Bluesky renders one embed.
  # ⚠️ A photo that is gone is one that the 24-hour draft TTL removed. Without this check the job
  # would fail the post after the owner left the page.
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
  # ⚠️ The mentions and the link decide it, and the typography never does. The typography runs on
  # every draft, thus a count of the finished text would blame the handles for a post that names
  # nobody.
  # @param substituted [String] The text with the mentions in place and no typography.
  # @return [String] The name of the message below `admin.social.errors`.
  def too_long_key(post, substituted)
    return "too_long_link" if draft.bluesky_link_in_text(post).present?

    substituted == post[:text] ? "too_long" : "too_long_handles"
  end

  # One message about one post.
  #
  # ⚠️ Each form is a complete sentence in the locale file, and this method selects one: a draft
  # of one post says "That post", and a thread names the post by its number.
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
  # ⚠️ Bluesky has the shortest limit, but a mention makes the text of each network a different
  # length, and a plain name can be much longer than a handle.
  # @return [String, nil]
  def network_length_error(post, index)
    return post_message("too_long_mastodon", index) if draft.over_limit?("mastodon", post)
    return nil unless draft.over_limit?("threads", post)

    post_message("too_long_threads", index)
  end

  # Refuses a draft with a Markdown link that goes to a network with no rich text. The post would
  # reach a reader there as `[my post](https://…)`.
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

  # Refuses a topic that Meta will not take. Without this, `ThreadsPostJob` retries a draft that
  # can never work.
  #
  # ⚠️ It reads the ticked networks only. The field stays in the form while the Threads row is not
  # ticked, and a value that the owner left there must not refuse the draft.
  # @return [String, nil]
  def topic_error
    return nil unless selected_networks.include?(SocialPresenter::TOPIC_NETWORK)
    return nil if draft.topic.blank? || Threads.valid_topic?(draft.topic)

    t("bad_topic", limit: Threads::TOPIC_MAX_CHARACTERS)
  end

  # Refuses a field that holds the handle of a DIFFERENT network. Without this such a value
  # becomes plain words with no message, and each "@" comes out of the middle of it.
  #
  # ⚠️ It reads the ticked networks only: a field of another network changes nothing.
  # ⚠️ Plain words are never a mistake here. Refer to `SocialMentions::DIAGNOSTIC_SHAPES`.
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

    # ⚠️ A moment that has passed is not an error: the post then goes out at once, and the label
    # of the submit button says "Post now" for that same draft.
    # ⚠️ There is no limit on how far ahead this can be, on purpose. The job stays in the
    # scheduled set of Sidekiq until it runs.
    nil
  end

  # Asks Bluesky about each handle of the map, and refuses a draft that names one that the PDS
  # does not know. Without this, `Bluesky#mention_facets` drops that handle with no message.
  #
  # ⚠️ It runs only for a value that has the shape of a Bluesky handle. Plain words are the answer
  # for a person with no Bluesky account.
  # ⚠️ The budget is what makes this fail open, and not the timeout of one call. Several slow
  # calls together pass the 20-second rack-timeout, and no rescue catches that exception.
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
