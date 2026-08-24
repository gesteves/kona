# The shared code of the article lists: TrendingArticles and RelatedArticles. It has the filter
# that selects the candidate articles, and the complete card data that TrendingArticles puts in the
# cache. Each of the two services sets @articles, which is an Articles source, in its constructor.
module ArticleRanking
  # Increase this after a change to the shape of `payload`. ⚠️ The cache key of TrendingArticles
  # must contain this value, because that cache holds a full payload and not an id.
  PAYLOAD_VERSION = 5

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
      cover_image: cover_image_payload(article),
      sys: { id: article.sys&.id }
    }
  end

  # The fields of the cover image that the card view needs. It is a plain hash, thus it goes into
  # the cache as JSON.
  #
  # ⚠️ It holds no transformation URL, on purpose. The payload stays in the cache for an hour, and
  # a URL that this code makes would hide a change to IMAGES_URL or to IMAGE_HOST for that full
  # hour. ImagesHelper makes the URL when the view renders.
  # @param article [OpenStruct] The article.
  # @return [Hash, nil] The cover image fields, or nil when the article has no cover image.
  def cover_image_payload(article)
    cover = article.cover_image
    return if cover&.url.blank?

    {
      url: cover.url,
      width: cover.width,
      height: cover.height,
      content_type: cover.content_type,
      sys: { id: cover.sys&.id, published_version: cover.sys&.published_version }
    }
  end
end
