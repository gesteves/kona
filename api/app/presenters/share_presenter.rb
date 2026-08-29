# Presents the Share composer: the entries that the owner can share, and the networks that can take
# a post.
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

  # One entry of the article picker.
  Article = Data.define(:id, :title, :summary, :url, :published_at, :entry_type)

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

  # @return [Array<Article>] Each published entry, the newest first.
  attr_reader :articles
  # @return [Array<Network>] The three networks, in a stable order.
  attr_reader :networks

  # @param articles [Array<OpenStruct>] The raw list from Articles#list.
  # @param networks [Array<Network>] The rows that the controller made.
  # @param site_url [String] The base URL of the public site.
  def initialize(articles:, networks:, site_url:)
    @site_url = site_url.to_s.chomp("/")
    @networks = networks
    @articles = build_articles(articles)
  end

  # @return [Boolean] True when no entry is available, which is what a Contentful failure gives.
  def empty? = @articles.empty?

  # @return [Integer]
  def body_limit = BODY_LIMIT

  # @return [Integer]
  def warn_at = WARN_AT

  private

  # Keeps each published entry and makes the fields that the picker needs.
  #
  # ⚠️ This keeps a Short, thus it is not ArticleRanking#candidates. That method removes a Short,
  # because the trending widget shows full articles only. A Short is a published entry, and the
  # owner can share one.
  # @param articles [Array<OpenStruct>]
  # @return [Array<Article>]
  def build_articles(articles)
    Array(articles)
      .reject { |article| article.draft || article.path.blank? }
      .sort_by { |article| article.published_at.to_s }
      .reverse
      .map { |article| to_article(article) }
  end

  # @param article [OpenStruct]
  # @return [Article]
  def to_article(article)
    Article.new(
      id: article.sys&.id,
      title: article.title.to_s,
      summary: article.summary.to_s,
      url: "#{@site_url}#{article.path}",
      published_at: article.published_at,
      entry_type: article.entry_type
    )
  end
end
