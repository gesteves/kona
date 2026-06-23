module Api
  # The "Trending Articles" widget, ranked from Plausible analytics at request time (instead of baked
  # into the static build) so it tracks recent traffic instead of going stale between daily rebuilds.
  # Cached for an hour. Two flavors: every trending article, or all but a caller-supplied set of ids
  # (the page passes the ids of cards it already shows so trending doesn't repeat them). All ranking
  # lives in the TrendingArticles service; the card helpers render in the view.
  class ArticlesController < BaseController
    # Shape of a Contentful entry id (URL-safe alphanumerics). Anything else in the :ids segment is
    # garbage and dropped before it reaches the service — it can never match a real article anyway.
    EXCLUDE_ID_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/
    # A page only excludes the handful of cards it actually shows (~a dozen), so cap the honored set
    # well above that. Keeps an abusive caller from forcing us to build a giant exclusion set; the
    # ranking itself is unaffected (it's cached under a single id-independent key — see TrendingArticles).
    MAX_EXCLUDE_IDS = 50

    def trending
      render_trending TrendingArticles.new.all(count: 4)
    end

    def trending_excluding
      render_trending TrendingArticles.new.excluding(exclude_ids, count: 4)
    end

    private

    # Parse, sanitize, and bound the comma-separated :ids segment: drop blanks/garbage, dedupe, and cap.
    def exclude_ids
      params[:ids].to_s.split(",").map(&:strip).grep(EXCLUDE_ID_FORMAT).uniq.first(MAX_EXCLUDE_IDS)
    end

    def render_trending(articles)
      cache_widget(ttl: 1.hour)

      @articles = articles
      return render_empty if @articles.blank?

      render :trending
    end
  end
end
