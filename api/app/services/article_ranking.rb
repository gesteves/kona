# The shared code of the article lists that the app makes at request time: TrendingArticles and
# RelatedArticles. It has the filter that selects the candidate articles, and the complete card data
# that each list puts in the cache. Each of the two services sets @articles, which is an Articles
# source, in its constructor.
module ArticleRanking
  # Increase this after a change to the shape of `payload`. ⚠️ Each of the two lists puts `payload`
  # in the cache under its own key, thus each such key must contain this value. With one version
  # number for each service, one of the two served entries with no value for the new fields, for a
  # full TTL.
  PAYLOAD_VERSION = 4

  private

  # The published articles that are not a Short and that have a path. This does not include a draft
  # and a Short, and web does the same.
  def candidates
    @articles.list.reject { |a| a.draft || a.entry_type == "Short" || a.path.blank? }
  end

  # The fields that the card views render, thus the list in the cache is complete.
  def payload(article)
    {
      title: article.title,
      summary: article.summary,
      slug: article.slug,
      path: article.path,
      published_at: article.published_at,
      entry_type: article.entry_type,
      draft: article.draft,
      sys: { id: article.sys&.id }
    }
  end
end
