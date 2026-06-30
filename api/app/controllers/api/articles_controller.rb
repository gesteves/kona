module Api
  # The "Trending Articles" widget, ranked from Plausible analytics at request time (instead of baked
  # into the static build) so it tracks recent traffic instead of going stale between daily rebuilds.
  # Cached for an hour. Two flavors: every trending article, or all but one (the `:id` an article page
  # passes for itself, so trending never lists the post you're reading). All ranking lives in the
  # TrendingArticles service; the card helpers render in the view.
  class ArticlesController < BaseController
    # Shape of a Contentful entry id (URL-safe alphanumerics). Anything else in the `:id` segment is
    # garbage — it can never match a real article, so we ignore it rather than acting on it.
    ID_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/

    def trending
      render_trending TrendingArticles.new.all(count: 4)
    end

    # Trending minus the `:id` article (the page passes its own id so it isn't listed as trending).
    def trending_excluding
      id = params[:id].to_s
      ids = id.match?(ID_FORMAT) ? [id] : []
      render_trending TrendingArticles.new.excluding(ids, count: 4)
    end

    # The "You May Also Like" widget: articles semantically related to :id (its Contentful entry id),
    # ranked by embedding similarity in the RelatedArticles service.
    def related
      cache_widget(ttl: 1.hour, edge_stale_while_revalidate: 1.day)

      id = params[:id].to_s
      @articles = id.match?(ID_FORMAT) ? RelatedArticles.new.for_article(id, count: 4) : []
      return render_empty if @articles.blank?

      render :related
    end

    private

    def render_trending(articles)
      cache_widget(ttl: 1.hour, edge_stale_while_revalidate: 1.day)

      @articles = articles
      return render_empty if @articles.blank?

      render :trending
    end
  end
end
