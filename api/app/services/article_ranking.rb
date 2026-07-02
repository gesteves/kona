# Shared behavior for the request-time article rankings (TrendingArticles, RelatedArticles):
# the candidate corpus filter and the self-contained card payload the rankings cache. Both
# services set @articles (an Articles corpus source) in their constructors.
module ArticleRanking
  private

  # Published, non-Short articles with a resolvable path (drafts/Shorts excluded — matches web).
  def candidates
    @articles.list.reject { |a| a.draft || a.entry_type == "Short" || a.path.blank? }
  end

  # The fields the card views render, so the cached ranking is self-contained.
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
