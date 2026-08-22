# Makes the shared article fields from the raw Contentful values. It is the one place in the API
# that decides the canonical article path, and that path must stay the same as the permalink from
# the web build.
module ArticleAttributes
  module_function

  # Makes the shared fields of a raw article item.
  # @param slug [String, nil] The slug of the entry.
  # @param published_version [Object, nil] sys.publishedVersion. A blank value means a draft.
  # @param published [String, nil] The publish date that an editor sets, if there is one.
  # @param first_published_at [String, nil] sys.firstPublishedAt.
  # @param body [String, nil] A full Article has one, and a Short has none.
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

  # @return [String, nil] The canonical article path, or nil when the code cannot make it.
  def path(slug:, published_at:, draft: false)
    return if draft || slug.blank? || published_at.blank?

    "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
  end
end
