module Widgets
  # The "Trending Articles" widget. The Plausible analytics give its order at request time, and the
  # static build does not contain it. Thus it follows the recent traffic and it does not become old
  # between two daily builds. The cache holds it for one hour. There are two forms: each trending
  # article, or each trending article but one. An article page gives its own `:id` for that second
  # form, thus the widget never lists the post that you read. The TrendingArticles service makes the
  # order, and the card helpers render in the view.
  class ArticlesController < BaseController
    def trending
      render_trending TrendingArticles.new.all(count: 4)
    end

    # The trending list without the article of the `:id`. The page gives its own id, thus the widget
    # does not list that page. The code ignores an id with an incorrect shape (refer to
    # BaseController::CONTENTFUL_ID_FORMAT).
    def trending_excluding
      id = contentful_id_param
      render_trending TrendingArticles.new.excluding(id ? [ id ] : [], count: 4)
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
