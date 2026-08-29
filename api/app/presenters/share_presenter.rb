# Presents the Share composer: the draft, and the networks that can take a post.
#
# ⚠️ The caller gives the state of each network, and this class does not read it, exactly as
# ConnectedAppPresenter needs. Thus the view makes no service call.
class SharePresenter
  # The maximum length of the body, in graphemes. It is the limit of Bluesky, which is the shortest
  # of the three. ⚠️ The view writes this number into the markup and share_controller.js reads it
  # there. Do not write it again in the JavaScript or in a stylesheet.
  BODY_LIMIT = 300

  # The length at which the count line changes to the warning color.
  WARN_AT = 270

  # One row of the "Post to" list.
  Network = Data.define(:key, :name, :account, :connected) do
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
  # @return [String] The draft body. It is blank on a first load.
  attr_reader :body
  # @return [String] The link to share. It is blank on a first load.
  attr_reader :article_url

  # @param networks [Array<Network>] The rows that the controller made.
  # @param body [String, nil] The draft to put back in the field. ⚠️ A failed submit renders this
  #   page again, thus the owner must not lose 300 characters that they wrote.
  # @param article_url [String, nil] The link to put back.
  # @param selected [Array<String>] The network keys to tick again.
  # @param scheduled [Boolean] True to open the schedule fields again.
  # @param date [String, nil] The date to put back, as YYYY-MM-DD.
  # @param time [String, nil] The time to put back, as HH:mm.
  def initialize(networks:, body: nil, article_url: nil, selected: [],
                 scheduled: false, date: nil, time: nil)
    @networks = networks
    @body = body.to_s
    @article_url = article_url.to_s
    @selected = Array(selected).map(&:to_s)
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

  # @param key [String] A network key.
  # @return [Boolean] True when the owner ticked that network.
  def selected?(key) = @selected.include?(key.to_s)

  # @return [Integer]
  def body_limit = BODY_LIMIT

  # @return [Integer]
  def warn_at = WARN_AT
end
