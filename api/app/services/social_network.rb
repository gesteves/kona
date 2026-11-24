# One network that the Social media page can post to, and what it takes: its job, its limits, and
# what it does with a link, a Markdown link, and a topic. Each limit comes from the class of that
# network.
#
# ⚠️ ALL is the one list, in the order of the page: a network that is not here cannot take a post.
# `Admin::SocialController` needs a `<key>_status` method for each key.
class SocialNetwork
  # @return [String] "bluesky", "mastodon", or "threads".
  attr_reader :key

  # @return [Class] The job that posts to this network.
  attr_reader :job

  # @return [Integer] The most characters of one post. Refer to `SocialDraft#length_for` for the
  #   rule that counts them.
  attr_reader :length_limit

  # The most photos on one post. ⚠️ A network takes the draft only when each post fits. The
  # composer disables a row whose limit is below the largest post, and
  # `SocialDraftValidator#photos_network_error` refuses a request that ticks one.
  # @return [Integer]
  attr_reader :photo_limit

  # @return [Integer] The most characters of the alt text of one photo.
  attr_reader :alt_limit

  # Where the link of a post goes.
  # - :card — Bluesky. This app makes an embed from the og: tags of the page, and the link goes in
  #   the words only when the page gives no card.
  # - :text — Mastodon. The link is below the words, and the instance makes its own card.
  # - :attachment — Threads. Meta makes an attachment, and the link uses none of the characters.
  # @return [Symbol]
  attr_reader :link

  def initialize(key:, job:, length_limit:, photo_limit:, alt_limit:, link:, markdown: false, topic: false)
    @key = key
    @job = job
    @length_limit = length_limit
    @photo_limit = photo_limit
    @alt_limit = alt_limit
    @link = link
    @markdown = markdown
    @topic = topic
  end

  # @return [String] The name of the network, for the page and for a message.
  def name = I18n.t("admin.networks.#{key}")

  # ⚠️ Only Bluesky has rich text: a Markdown link becomes a facet there, and the URL uses none of
  # the characters. The other two post plain words, thus a link there would reach a reader as its
  # own syntax. The composer disables those rows, and
  # `SocialDraftValidator#markdown_network_error` refuses a request that ticks one.
  # @return [Boolean] True when the network takes a Markdown link.
  def markdown? = @markdown

  # ⚠️ `topic_tag` is a parameter of Meta, and it has no equivalent at Bluesky or Mastodon. Thus
  # the topic field shows only while the Threads row is ticked.
  # @return [Boolean] True when the network takes a topic.
  def topic? = @topic

  ALL = [
    new(key: "bluesky", job: BlueskyPostJob, link: :card, markdown: true,
        length_limit: Bluesky::MAX_GRAPHEMES, photo_limit: Bluesky::MAX_IMAGES,
        alt_limit: Bluesky::MAX_ALT_GRAPHEMES),
    new(key: "mastodon", job: MastodonPostJob, link: :text,
        length_limit: Mastodon::DEFAULT_MAX_CHARACTERS, photo_limit: Mastodon::MAX_MEDIA_ATTACHMENTS,
        alt_limit: Mastodon::MAX_DESCRIPTION_CHARACTERS),
    new(key: "threads", job: ThreadsPostJob, link: :attachment, topic: true,
        length_limit: Threads::MAX_CHARACTERS, photo_limit: Threads::MAX_CAROUSEL_ITEMS,
        alt_limit: Threads::MAX_ALT_TEXT_CHARACTERS)
  ].freeze

  # The most photos on one post of the page. ⚠️ It is the limit of Bluesky and not the largest
  # limit. The Bluesky row has no `data-max-photos`, thus the composer cannot turn it off for a
  # count that it refuses.
  MAX_PHOTOS = Bluesky::MAX_IMAGES

  # The limit of the alt text of one photo of the page. One alt text goes to each network, thus
  # the limit is the smallest one.
  ALT_LIMIT = ALL.map(&:alt_limit).min

  # @return [Array<SocialNetwork>] Each network, in the order of the page.
  def self.all = ALL

  # @return [Array<String>]
  def self.keys = ALL.map(&:key)

  # @param key [String] A network key.
  # @return [SocialNetwork, nil] Nil for a key that is not in ALL.
  def self.find(key) = ALL.find { |network| network.key == key.to_s }

  # @param key [String] A network key.
  # @return [SocialNetwork]
  # @raise [KeyError] For a key that is not in ALL.
  def self.fetch(key) = find(key) || raise(KeyError, "no social network #{key.inspect}")
end
