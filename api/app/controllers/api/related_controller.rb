module Api
  # Serves every entry's nearest neighbors, which the web build bakes into each article's static
  # "You May Also Like" section. The ranking is the only part of that section the build can't
  # compute for itself — it has every article's own fields already — so this returns bare
  # Contentful ids rather than card payloads.
  #
  # Bearer-gated like the other build-time endpoints, and deliberately not edge-cached: it's
  # fetched once per build, immediately after the publish that triggered it, so a cached copy
  # would be wrong in exactly the case that matters.
  class RelatedController < BaseController
    # How many neighbors each entry gets. The web build renders up to this many; it slices if
    # it wants fewer, so the two don't have to agree.
    COUNT = 4

    def show
      render json: RelatedArticles.new.all(count: COUNT)
    end
  end
end
