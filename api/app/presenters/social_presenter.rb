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

  # The most posts in one thread. ⚠️ It is a guard against a runaway form and not a rule of any
  # network: Bluesky and Mastodon set no limit, and the limit of Threads is a rate of 250 each day.
  MAX_POSTS = 25

  # One post of the thread. `link` is optional, thus a post can be words alone.
  Post = Data.define(:text, :link) do
    def initialize(text: "", link: "") = super(text: text.to_s, link: link.to_s)
  end

  # One row of the "Post to" list.
  Network = Data.define(:key, :name, :account, :connected, :notice) do
    # @param notice [String, nil] The reason for a row that cannot take a post, for example an
    #   expired token. Nil gives the default "Not connected." of the view.
    def initialize(key:, name:, account: nil, connected: false, notice: nil) = super

    def connected? = connected

    # The line below the name, for a network that is connected. The view renders its own line, with
    # a link, for a network that is not connected.
    # @return [String]
    def account_line
      account.present? ? "Posts as #{account}." : "Connected."
    end
  end

  # @return [Array<Network>] The three networks, in a stable order.
  attr_reader :networks
  # @return [Array<Post>] Each post of the thread, in order. There is always at least one, thus the
  #   view renders one empty block on a first load.
  attr_reader :posts

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
  def initialize(networks:, posts: nil, selected: nil,
                 scheduled: false, date: nil, time: nil)
    @networks = networks
    @posts = build_posts(posts)
    @selected = selected.nil? ? networks.select(&:connected?).map(&:key) : Array(selected).map(&:to_s)
    @scheduled = scheduled
    @date = date.to_s
    @time = time.to_s
  end

  # @return [Boolean] True when the schedule fields are open.
  def scheduled? = @scheduled

  # @return [String] The date field, as YYYY-MM-DD.
  attr_reader :date
  # @return [String] The time field, as HH:mm.
  attr_reader :time

  # The first day that the date field offers. ⚠️ It is in the zone of the **server**, thus a browser
  # that is a day ahead can still pick its own today. The action checks that the moment is in the
  # future, and that check is the one that matters.
  # @return [String] YYYY-MM-DD.
  def min_date = Time.use_zone(TimeZoneResolver.default) { Time.zone.today.to_fs(:iso8601) }

  # ⚠️ There is no `max_date`, on purpose. The owner can schedule a post as far ahead as they want.

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
