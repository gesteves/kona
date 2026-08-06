# Derives the shared article fields from raw Contentful values. The single owner of the
# canonical article path format on the API side; it must keep matching the web build's
# permalinks.
module ArticleAttributes
  module_function

  # Derives the shared fields for a raw article item.
  # @param slug [String, nil] The entry's slug.
  # @param published_version [Object, nil] sys.publishedVersion; blank means draft.
  # @param published [String, nil] The editorial publish date, if set.
  # @param first_published_at [String, nil] sys.firstPublishedAt.
  # @param body [String, nil] Present for a full Article, blank for a Short.
  # @return [Hash] { draft:, published_at:, entry_type:, path: }
  def derive(slug:, published_version:, published:, first_published_at:, body: nil)
    draft = published_version.blank?
    published_at = published.presence || first_published_at

    {
      draft: draft,
      published_at: published_at,
      entry_type: body.present? ? "Article" : "Short",
      path: path(slug: slug, published_at: published_at, draft: draft)
    }
  end

  # @return [String, nil] The canonical article path, or nil when it can't be resolved.
  def path(slug:, published_at:, draft: false)
    return if draft || slug.blank? || published_at.blank?

    "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
  end
end
