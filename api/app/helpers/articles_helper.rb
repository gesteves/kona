module ArticlesHelper
  # A permalink <a> whose text is the publication date (the no-JS fallback). The publish-date
  # Stimulus controller swaps in a live relative timestamp client-side for recent articles.
  def article_permalink_timestamp(article)
    published = DateTime.parse(article.published_at)
    options = {
      href: article.path,
      title: "Published at #{published.strftime('%-I:%M %p')}",
      "data-publish-date-target": "timestamp"
    }
    link = content_tag :a, options do
      published.strftime("%A, %B %-e, %Y")
    end
    # Wrap in a <time> so the ISO publish instant is machine-readable. The Stimulus controller
    # swaps the inner <a>'s content for recent posts; this wrapper (and its datetime) is untouched.
    content_tag :time, link, datetime: published.iso8601
  end
end
