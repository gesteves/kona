module Api
  # Gives the nearest neighbors of each entry. The web build puts them into the static "You May Also
  # Like" section of each article. The order is the one part of that section that the build cannot
  # calculate, because it already has the fields of each article. Thus this endpoint returns the
  # Contentful ids only, and not the data of a card.
  #
  # It needs a bearer token, as the other build-time endpoints do, and the edge does not cache it, on
  # purpose: the build gets it one time, immediately after the publish that started the build. Thus a
  # copy in the cache would be wrong in the one condition that is important.
  class RelatedController < BaseController
    # The number of neighbors of each entry. The web build renders this number or fewer: it takes
    # part of the list if it wants fewer. Thus the two numbers do not need to agree.
    #
    # ⚠️ This is larger than the four cards that a section shows, and it needs to be. A race report
    # renders two sections, and the build removes from the related list each entry that the
    # race-report section already holds. Without the extra neighbors, that dedup makes the second
    # section short. RelatedArticles::MAX_POOL is the limit above this number.
    COUNT = 8

    def show
      # ⚠️ Say it, and do not depend on the default of the edge for a path with no extension.
      response.headers["Cache-Control"] = "no-store"
      render json: RelatedArticles.new.all(count: COUNT)
    end
  end
end
