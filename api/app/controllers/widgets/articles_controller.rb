module Widgets
  # The "Trending Articles" widget, ranked from Plausible analytics at request time (instead of baked
  # into the static build) so it tracks recent traffic instead of going stale between daily rebuilds.
  # Cached for an hour. Two flavors: every trending article, or all but one (the `:id` an article page
  # passes for itself, so trending never lists the post you're reading). All ranking lives in the
  # TrendingArticles service; the card helpers render in the view.
  class ArticlesController < BaseController
    def trending
      render_trending TrendingArticles.new.all(count: 4)
    end

    # Trending minus the `:id` article (the page passes its own id so it isn't listed as trending).
    # A garbage id (see BaseController::CONTENTFUL_ID_FORMAT) is ignored rather than acted on.
    def trending_excluding
      id = contentful_id_param
      render_trending TrendingArticles.new.excluding(id ? [id] : [], count: 4)
    end

    # The "You May Also Like" widget: articles semantically related to :id (its Contentful entry id),
    # ranked by embedding similarity in the RelatedArticles service.
    def related
      render_widget(:related, ttl: 1.hour, edge_stale_while_revalidate: 1.day) do
        id = contentful_id_param
        @articles = id ? RelatedArticles.new.for_article(id, count: 4) : []
      end
    end

    private

    def render_trending(articles)
      render_widget(:trending, ttl: 1.hour, edge_stale_while_revalidate: 1.day) { @articles = articles }
    end
  end
end
