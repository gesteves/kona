# Presents the Social media page: the draft, and the networks that can take a post.
#
# ⚠️ The caller gives the state of each network, and this class does not read it, exactly as
# ConnectedAppPresenter needs. Thus the view makes no service call.
class SocialPresenter
  # The maximum length of the body, in graphemes. It is the limit of Bluesky, which is the shortest
  # of the three. ⚠️ The view writes this number into the markup and social_controller.js reads it
  # there. Do not write it again in the JavaScript or in a stylesheet.
  BODY_LIMIT = 300

  # The length at which the count line changes to the warning color.
  WARN_AT = 270

  # The one network with rich text. ⚠️ A Markdown link becomes a facet there: the words carry the
  # address and the URL uses none of the 300 characters. Mastodon and Threads post plain words,
  # thus a link there would reach a reader as its own syntax with the address gone. The composer
  # unticks and disables those two rows, and `Admin::SocialController#markdown_network_error`
  # refuses a request that ticks one anyway.
  MARKDOWN_NETWORK = "bluesky".freeze

  # The one network that takes a topic. ⚠️ `topic_tag` is a parameter of Meta and it has no
  # equivalent at Bluesky or Mastodon, thus the field shows only while that row is ticked.
  TOPIC_NETWORK = "threads".freeze

  # The most posts in one thread. ⚠️ It is a guard against a runaway form and not a rule of any
  # network: Bluesky and Mastodon set no limit, and the limit of Threads is a rate of 250 each day.
  MAX_POSTS = 25

  # One post of the thread. `link` is optional, thus a post can be words alone.
  Post = Data.define(:text, :link) do
    def initialize(text: "", link: "") = super(text: text.to_s, link: link.to_s)
  end

  # The example that each mention field shows. ⚠️ It is an example of a HANDLE only. A field also
  # takes plain words, for a person with no account there, and the hint of the section says so.
  # @return [Hash{String=>String}] Each network key, and its example.
  def self.mention_placeholders
    %w[bluesky mastodon threads].index_with { |key| I18n.t("admin.social.mention_placeholder.#{key}") }
  end

  # One row of the mention map: the token that the owner wrote, and what that person is called at
  # each network.
  #
  # ⚠️ The map is THREAD-LEVEL. There is one map for the whole draft, thus a token means the same
  # person in every post of it.
  Mention = Data.define(:token, :values) do
    def initialize(token:, values: {})
      super(token: token.to_s, values: values.to_h.transform_keys(&:to_s))
    end

    # @param key [String] A network key.
    # @return [String] The field of that network: a handle, plain words, or an empty string.
    def value(key) = values[key.to_s].to_s
  end

  # One row of the "Post to" list.
  Network = Data.define(:key, :name, :account, :connected, :notice) do
    # @param notice [String, nil] The reason for a row that cannot take a post, for example an
    #   expired token. Nil gives the default "Not connected." of the view.
    def initialize(key:, name:, account: nil, connected: false, notice: nil) = super

    def connected? = connected

    # @return [Boolean] True for the one network that takes a Markdown link.
    def markdown? = key == MARKDOWN_NETWORK

    # The line below the name, for a network that is connected. The view renders its own line, with
    # a link, for a network that is not connected.
    # @return [String]
    def account_line
      if account.present?
        I18n.t("admin.social.account.named", account: account)
      else
        I18n.t("admin.social.account.unnamed")
      end
    end
  end

  # @return [Array<Network>] The three networks, in a stable order.
  attr_reader :networks
  # @return [Array<Post>] Each post of the thread, in order. There is always at least one, thus the
  #   view renders one empty block on a first load.
  attr_reader :posts
  # @return [Array<Mention>] One row for each token of the draft, in the order of the form.
  attr_reader :mentions

  # @param networks [Array<Network>] The rows that the controller made.
  # @param posts [Array<Hash>, nil] The thread to put back, as `[{ text:, link: }, …]`. ⚠️ A failed
  #   submit renders this page again, thus the owner must not lose what they wrote. Nil, the first
  #   load, gives one empty post.
  # @param selected [Array<String>, nil] The network keys to tick. ⚠️ Nil, the first load, ticks
  #   each connected network: the owner posts to all of them nearly always, and the page must not
  #   ask for three clicks each time. An array is the choice of the owner, and an empty one ticks
  #   nothing.
  # @param scheduled [Boolean] True to open the schedule fields again.
  # @param date [String, nil] The date to put back, as YYYY-MM-DD.
  # @param time [String, nil] The time to put back, as HH:mm.
  # @param topic [String, nil] The Threads topic to put back. ⚠️ It belongs to the DRAFT and not to
  #   one post: Meta takes one topic for each post, and the composer puts it on the first alone.
  # @param mentions [Array<Hash>, nil] The mention map to put back, as
  #   `[{ token:, values: { "bluesky" => … } }, …]`. ⚠️ Nil gives NO row, and not one empty row:
  #   a row for nothing would ask the owner to name a person that they did not write about. The
  #   browser adds a row when it finds a token.
  def initialize(networks:, posts: nil, mentions: nil, selected: nil,
                 scheduled: false, date: nil, time: nil, topic: nil)
    @networks = networks
    @posts = build_posts(posts)
    @mentions = Array(mentions).map { |row| Mention.new(token: row[:token], values: row[:values]) }
    @selected = selected.nil? ? networks.select(&:connected?).map(&:key) : Array(selected).map(&:to_s)
    @scheduled = scheduled
    @date = date.to_s
    @time = time.to_s
    @topic = topic.to_s
  end

  # @return [Boolean] True when the schedule fields are open.
  def scheduled? = @scheduled

  # @return [String] The date field, as YYYY-MM-DD.
  attr_reader :date
  # @return [String] The time field, as HH:mm.
  attr_reader :time
  # @return [String] The Threads topic field.
  attr_reader :topic

  # The first day that the date field offers. ⚠️ It is in the zone of the **server**, thus a browser
  # that is a day ahead can still pick its own today. The action checks that the moment is in the
  # future, and that check is the one that matters.
  # @return [String] YYYY-MM-DD.
  def min_date = Time.use_zone(TimeZoneResolver.default) { Time.zone.today.to_fs(:iso8601) }

  # ⚠️ There is no `max_date`, on purpose. The owner can schedule a post as far ahead as they want.

  # @return [Boolean] True when the draft names at least one person. The section is hidden when it
  #   is false, and social_controller.js shows it at the first token.
  def mentions? = @mentions.any?

  # The networks that a mention row asks about.
  #
  # ⚠️ **A network with no account gets NO field.** That is different from the "Post to" list, which
  # keeps a disabled row to say why one of three names cannot take a post. Here there is nothing to
  # say: a field for an account that cannot take a post is only noise.
  #
  # ⚠️ Each row renders the SAME list, thus the order of `mentions[][…]` cannot drift between two
  # rows. Refer to the ⚠️ in _mention.html.erb.
  # @return [Array<Network>]
  def mention_networks = networks.select(&:connected?)

  # The Bluesky field of each mention, by key, with each blank one dropped.
  #
  # ⚠️ The COUNT reads this one, and not the map of another network. Bluesky has the shortest limit
  # and the longest handles, thus its text is the one that decides if a draft fits.
  # @return [Hash{String => String}]
  def bluesky_values
    @bluesky_values ||= @mentions.each_with_object({}) do |mention, map|
      value = mention.value("bluesky")
      map[SocialMentions.key(mention.token)] = value if value.present?
    end
  end

  # ⚠️ Each post block carries this in a data attribute, thus the count that the SERVER rendered and
  # the first count of the browser are the same number. Refer to social_post_controller.js.
  # @return [String]
  def bluesky_values_json = bluesky_values.to_json

  # @param post [Post]
  # @return [Integer] The graphemes that Bluesky will count for that post, after the handles go in.
  # ⚠️ The steps and their order are the ones of `Admin::SocialController#text_for`. Thus the count
  # that the server renders and the first count of the browser are the same number.
  def bluesky_length(post)
    Bluesky.post_length(
      Typography.apply(SocialMentions.substitute(post.text, values: bluesky_values,
                                                 network: "bluesky"))
    )
  end

  # @param key [String] A network key.
  # @return [String, nil]
  def mention_placeholder(key) = self.class.mention_placeholders[key.to_s]

  # ⚠️ The server renders the field hidden when the Threads row is not ticked, thus it does not
  # show for a moment before the Stimulus controller runs. `social#applyTopic` follows each change
  # after that, and it reads the same rule.
  # @return [Boolean] True when the topic field shows.
  def topic?
    network = networks.find { |row| row.key == TOPIC_NETWORK }

    network&.connected? && selected?(TOPIC_NETWORK) || false
  end

  # @return [Boolean] True when the draft is a thread and not one post.
  def thread? = @posts.length > 1

  # @return [Integer]
  def max_posts = MAX_POSTS

  # @param key [String] A network key.
  # @return [Boolean] True when the row is ticked.
  def selected?(key) = @selected.include?(key.to_s)

  # @return [Integer]
  def body_limit = BODY_LIMIT

  # @return [Integer]
  def warn_at = WARN_AT

  private

  # ⚠️ There is always at least one post, thus the view renders one empty block on a first load and
  # after a refusal that emptied the form.
  # @param posts [Array<Hash>, nil]
  # @return [Array<Post>]
  def build_posts(posts)
    built = Array(posts).map { |post| Post.new(text: post[:text], link: post[:link]) }
    built.presence || [ Post.new ]
  end
end
