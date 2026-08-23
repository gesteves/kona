module Widgets
  # The "Trending Articles" widget. The Plausible analytics give its order at request time, and the
  # static build does not contain it. Thus it follows the recent traffic and it does not become old
  # between two daily builds. The cache holds it for one hour. The TrendingArticles service makes
  # the order, and the card helpers render in the view.
  #
  # ⚠️ The home page and a Page render this widget, and an entry page does not. That page already
  # has "More Reports From This Race", "You May Also Like", and the Previous and Next cards.
  class ArticlesController < BaseController
    def trending
      render_trending TrendingArticles.new.all(count: 4)
    end

    private

    # ⚠️ Keep the default edge stale-while-revalidate. A longer window makes each copy live for
    # max-age plus that window, thus a markup change stays out of some PoPs for that full time,
    # and a tag purge that misses gives no message.
    def render_trending(articles)
      render_widget(:trending, ttl: 1.hour) { @articles = articles }
    end
  end
end
