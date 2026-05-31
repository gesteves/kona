module ArticlesHelper
  # Whether the article was published today, in the current location's timezone.
  def published_today?(article)
    article_date = Time.parse(article.published_at).in_time_zone(location_time_zone)
    article_date.to_date == current_time.to_date
  end

  # Whether the article was published within the past week.
  def published_in_the_past_week?(article)
    article_date = Time.parse(article.published_at).in_time_zone(location_time_zone)
    article_date.to_date >= 1.week.ago.to_date
  end

  # Whether the article is "new": a Short is new the day it's published, a full Article for a
  # week. Drafts are never new. Drives the "New" badge on summary cards.
  def new_article?(article)
    return false if article.draft
    if article.entry_type == "Short"
      published_today?(article)
    else
      published_in_the_past_week?(article)
    end
  end

  # A permalink <a> whose text is the publication date; today's articles also carry the
  # relative-date Stimulus controller so the timestamp stays fresh client-side.
  def article_permalink_timestamp(article)
    options = {
      href: article.path,
      title: "Published at #{DateTime.parse(article.published_at).strftime('%-I:%M %p')}"
    }
    if published_today?(article) || article.draft
      options["data-controller"] = "relative-date"
      options["data-relative-date-datetime-value"] = DateTime.parse(article.published_at).iso8601
    end
    content_tag :a, options do
      DateTime.parse(article.published_at).strftime("%A, %B %-e, %Y")
    end
  end
end
