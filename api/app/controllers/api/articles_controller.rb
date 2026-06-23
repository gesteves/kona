module Api
  # The "Trending Articles" widget, ranked from Plausible analytics at request time (instead of baked
  # into the static build) so it tracks recent traffic instead of going stale between daily rebuilds.
  # Cached for an hour. Two flavors: every trending article, or all but a caller-supplied set of ids
  # (the page passes the ids of cards it already shows so trending doesn't repeat them). All ranking
  # lives in the TrendingArticles service; the card helpers render in the view.
  class ArticlesController < BaseController
    def trending
      render_trending TrendingArticles.new.all(count: 4)
    end

    def trending_excluding
      render_trending TrendingArticles.new.excluding(params[:ids].to_s.split(","), count: 4)
    end

    private

    def render_trending(articles)
      cache_widget(ttl: 1.hour)

      @articles = articles
      return render_empty if @articles.blank?

      render :trending
    end
  end
end
