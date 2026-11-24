# Presents the Social media page: the draft, and the networks that can take a post.
#
# ⚠️ The caller gives the state of each network, and this class does not read it. Thus the view
# makes no service call.
class SocialPresenter
  # The maximum length of the body, in graphemes: the limit of Bluesky, the shortest of the three.
  # ⚠️ The view writes this number into the markup and social_post_controller.js reads it there.
  # Do not write it again in the JavaScript or in a stylesheet.
  BODY_LIMIT = Bluesky::MAX_GRAPHEMES

  # The length at which the count line changes to the warning color.
  WARN_AT = 270

  # The options of the topic field: the interests of the owner in the Threads app. ⚠️ Meta gives no
  # endpoint that lists the topics, thus the list is here. Each one is a value that goes to Meta,
  # and not copy, thus it stays out of the locale file.
  TOPICS = [
    "IronmanTriathlon", "Triathlon", "Cycling Threads", "Running Threads", "Swimming Threads",
    "Fitness Threads"
  ].freeze

  # One photo of a post: the id that `SocialPhotos` made, and its alt text.
  Photo = Data.define(:id, :alt) do
    def initialize(id: "", alt: "") = super(id: id.to_s, alt: alt.to_s)
  end

  # One post of the thread. `link` and `photos` are optional, thus a post can be words alone.
  # ⚠️ A post takes a link OR photos, and not both: Bluesky renders one embed.
  Post = Data.define(:text, :link, :photos) do
    def initialize(text: "", link: "", photos: [])
      super(text: text.to_s, link: link.to_s,
            photos: Array(photos).map { |photo| photo.is_a?(Photo) ? photo : Photo.new(**photo.to_h.symbolize_keys) })
    end
  end

  # The example that each mention field shows. ⚠️ It is an example of a HANDLE only. A field also
  # takes plain words, for a person with no account there, and the hint of the section says so.
  # @return [Hash{String=>String}] Each network key, and its example.
  def self.mention_placeholders
    SocialNetwork.keys.index_with { |key| I18n.t("admin.social.mention_placeholder.#{key}") }
  end

  # One row of the mention map: the token that the owner wrote, and the name of that person at
  # each network. ⚠️ There is one map for the whole draft, thus a token means the same person in
  # each post.
  Mention = Data.define(:token, :values) do
    def initialize(token:, values: {})
      super(token: token.to_s, values: values.to_h.transform_keys(&:to_s))
    end

    # @return [String] The field of that network: a handle, plain words, or an empty string.
    def value(key) = values[key.to_s].to_s
  end

  # One row of the "Post to" list.
  Network = Data.define(:key, :name, :account, :connected, :notice) do
    # @param notice [String, nil] The reason for a row that cannot take a post, for example an
    #   expired token. Nil gives the default "Not connected." of the view.
    def initialize(key:, name:, account: nil, connected: false, notice: nil) = super

    def connected? = connected

    # What the network of this row takes. Refer to SocialNetwork.
    delegate :markdown?, :topic?, to: :network

    def max_photos = network.photo_limit

    # @return [Boolean] True when too many photos can turn this row off, thus it needs a hint line
    #   for that reason.
    def photo_limited? = max_photos < SocialNetwork::MAX_PHOTOS

    def network = SocialNetwork.fetch(key)

    # The line below the name, for a network that is connected. The view renders its own line, with
    # a link, for a network that is not connected.
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
  # @return [Array<Post>] Each post of the thread, in order. There is always at least one.
  attr_reader :posts
  # @return [Array<Mention>] One row for each token of the draft, in the order of the form.
  attr_reader :mentions

  # @param networks [Array<Network>] The rows that the controller made.
  # @param posts [Array<Hash>, nil] The thread to put back, as `[{ text:, link:, photos: }, …]`.
  #   ⚠️ A failed submit renders this page again, thus the owner must not lose what they wrote.
  #   Nil, the first load, gives one empty post.
  # @param selected [Array<String>, nil] The network keys to tick. ⚠️ Nil, the first load, ticks
  #   each connected network, because the owner posts to all of them nearly always. An array is
  #   the choice of the owner, and an empty one ticks nothing.
  # @param scheduled [Boolean] True to open the schedule fields again.
  # @param date [String, nil] The date to put back, as YYYY-MM-DD.
  # @param time [String, nil] The time to put back, as HH:mm.
  # @param topic [String, nil] The Threads topic to put back. ⚠️ It belongs to the draft and not to
  #   one post: Meta takes one topic for each post, and each post of a thread carries this one.
  # @param mentions [Array<Hash>, nil] The mention map to put back, as
  #   `[{ token:, values: { "bluesky" => … } }, …]`. ⚠️ Nil gives no row, and not one empty row:
  #   an empty row would ask the owner to name a person that they did not write about. The browser
  #   adds a row when it finds a token.
  # @param alt_text [Boolean] True when Claude can write the alt text of a photo, thus each tile
  #   renders its Generate control. ⚠️ The caller reads the configuration, and this class does not.
  def initialize(networks:, posts: nil, mentions: nil, selected: nil,
                 scheduled: false, date: nil, time: nil, topic: nil, alt_text: false)
    @networks = networks
    @alt_text = alt_text
    @posts = build_posts(posts)
    @mentions = Array(mentions).map { |row| Mention.new(token: row[:token], values: row[:values]) }
    @selected = selected.nil? ? networks.select(&:connected?).map(&:key) : Array(selected).map(&:to_s)
    @scheduled = scheduled
    @date = date.to_s
    @time = time.to_s
    @topic = topic.to_s
  end

  def scheduled? = @scheduled

  # @return [Boolean] True when each tile renders its Generate control.
  def alt_text? = @alt_text

  attr_reader :date
  attr_reader :time
  attr_reader :topic

  # The first day that the date field offers. ⚠️ It is in the zone of the server, thus a browser
  # that is a day ahead can still pick its own today. The action checks that the moment is in the
  # future.
  # @return [String] YYYY-MM-DD.
  def min_date = Time.use_zone(TimeZoneResolver.default) { Time.zone.today.to_fs(:iso8601) }

  # ⚠️ There is no `max_date`, on purpose. The owner can schedule a post as far ahead as they want.

  # @return [Boolean] True when the draft names at least one person. The section is hidden when it
  #   is false, and lib/mention_rows.js shows it at the first token.
  def mentions? = @mentions.any?

  # The networks that a mention row asks about.
  #
  # ⚠️ A network with no account gets no field. The "Post to" list keeps a disabled row to say why
  # a network cannot take a post, and here there is nothing to say.
  #
  # ⚠️ Each row renders the same list, thus the order of `mentions[][…]` is the same in each row.
  # Refer to the ⚠️ in _mention.html.erb.
  # @return [Array<Network>]
  def mention_networks = networks.select(&:connected?)

  # The Bluesky field of each mention, by key, with no blank one.
  #
  # ⚠️ The count reads this map, and not the map of another network. Bluesky has the shortest limit
  # and the longest handles, thus its text decides if a draft fits.
  # @return [Hash{String => String}]
  def bluesky_values
    @bluesky_values ||= @mentions.each_with_object({}) do |mention, map|
      value = mention.value("bluesky")
      map[SocialMentions.key(mention.token)] = value if value.present?
    end
  end

  # ⚠️ Each post block carries this in a data attribute, thus the browser counts with the same map
  # as the server. Refer to social_post_controller.js.
  def bluesky_values_json = bluesky_values.to_json

  # ⚠️ The steps and their order are the ones of `SocialDraft#text_for`. Thus the count that the
  # server renders and the first count of the browser are the same number.
  # @param post [Post]
  # @return [Integer] The graphemes that Bluesky counts for that post, after the handles go in.
  def bluesky_length(post)
    Bluesky.post_length(
      Typography.apply(SocialMentions.substitute(post.text, values: bluesky_values,
                                                 network: "bluesky"))
    )
  end

  # @return [String, nil] The example of that network.
  def mention_placeholder(key) = self.class.mention_placeholders[key.to_s]

  # ⚠️ The server renders the field hidden when the Threads row is not ticked, thus it does not
  # show for a moment before the Stimulus controller runs. `social#applyTopic` reads the same rule
  # at each later change.
  # @return [Boolean] True when the topic field shows.
  def topic?
    network = networks.find(&:topic?)

    (network&.connected? && selected?(network.key)) || false
  end

  # ⚠️ The combobox shows a value only through an option that matches it. Without the extra option,
  # a topic that the owner typed goes with the form but the field looks empty after a refusal.
  # @return [Array<String>] Each of TOPICS, then the topic of the draft when it is not one of them.
  def topic_options
    topic.blank? || TOPICS.include?(topic) ? TOPICS : TOPICS + [ topic ]
  end

  def max_posts = SocialDraft::MAX_POSTS

  def max_photos = SocialNetwork::MAX_PHOTOS

  def alt_limit = SocialNetwork::ALT_LIMIT

  # @return [Boolean] True when the row is ticked.
  def selected?(key) = @selected.include?(key.to_s)

  def body_limit = BODY_LIMIT

  def warn_at = WARN_AT

  private

  # ⚠️ There is always at least one post, thus the view renders one empty block on a first load and
  # after a refusal that emptied the form.
  # @return [Array<Post>]
  def build_posts(posts)
    built = Array(posts).map { |post| Post.new(text: post[:text], link: post[:link], photos: post[:photos]) }
    built.presence || [ Post.new ]
  end
end
