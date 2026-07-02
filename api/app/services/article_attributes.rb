# Derives the shared article fields (draft / published_at / entry_type / path) from raw
# Contentful values. This is the single owner of the canonical article path format
# (/%Y/%m/%d/slug/) on the API side — it must keep matching the web build's permalinks
# (web's set_draft_status / set_entry_type / set_article_path), and it was previously
# re-implemented in Articles, StandardSite, and PlausibleController.
module ArticleAttributes
  module_function

  # The derived fields for a raw article item's values.
  # @param slug [String, nil]
  # @param published_version [Object, nil] sys.publishedVersion — blank means draft.
  # @param published [String, nil] The optional editorial publish date.
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

  # The canonical article path, or nil when it can't be resolved.
  # @return [String, nil]
  def path(slug:, published_at:, draft: false)
    return if draft || slug.blank? || published_at.blank?

    "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
  end
end
