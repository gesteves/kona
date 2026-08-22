module ArticlesHelper
  # A permalink <a> whose text is the publish date. That is the result with no JavaScript. For a
  # recent article, the publish-date Stimulus controller puts a live relative time in its place, in
  # the browser.
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
    # Put this in a <time>, thus a machine can read the ISO publish instant. The Stimulus controller
    # changes the content of the <a> in it for a recent post, and this element, with its datetime,
    # does not change.
    content_tag :time, link, datetime: published.iso8601
  end
end
