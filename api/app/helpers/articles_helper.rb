module ArticlesHelper
  # A permalink <a> whose text is the publication date (the no-JS fallback). The publish-date
  # Stimulus controller swaps in a live relative timestamp client-side for recent articles.
  def article_permalink_timestamp(article)
    options = {
      href: article.path,
      title: "Published at #{DateTime.parse(article.published_at).strftime('%-I:%M %p')}",
      "data-publish-date-target": "timestamp"
    }
    content_tag :a, options do
      DateTime.parse(article.published_at).strftime("%A, %B %-e, %Y")
    end
  end
end
