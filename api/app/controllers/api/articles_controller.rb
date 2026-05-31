module Api
  # The home page's "Trending Articles" section, ranked from Plausible analytics at request time
  # (instead of baked into the static build) so it tracks the 1-day/7-day traffic windows instead
  # of going stale between daily rebuilds. Cached for an hour. All ranking lives in the
  # TrendingArticles service; the card helpers render in the view.
  class ArticlesController < BaseController
    def trending
      cache_widget(ttl: 1.hour)

      @articles = TrendingArticles.new.non_recent(count: 4)
      return render_empty if @articles.blank?

      render :trending
    end
  end
end
