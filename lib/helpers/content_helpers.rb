require 'text'

module ContentHelpers
  # Returns the publicly-visible name for an entry type
  # @param entry [Object] The entry to check.
  # @return [String] The name of the entry type
  def entry_type(entry)
    return if entry.entry_type.blank?
    case entry.entry_type
    when 'Short'
      'Post'
    else
      entry.entry_type
    end
  end

  # Determines if the article was published today in the current timezone.
  # @param article [Object] The article.
  # @return [Boolean] If the article was published today.
  def published_today?(article)
    article_date = Time.parse(article.published_at).in_time_zone(location_time_zone)
    article_date.to_date == current_time.to_date
  end

  # Returns a permalink anchor tag for the article, with the date it was published.
  # If the article was published today, includes attributes to render the date as a relative timestamp.
  # @param article [Object] The article.
  # @return [String] An <a> tag linking to the article, with a relative or absolute date as the text.
  def article_permalink_timestamp(article)
    formatted = DateTime.parse(article.published_at).strftime('%A, %B %-e, %Y')
    options = {
      href: article.path
    }
    if published_today?(article) || article.draft
      options["data-controller"] = "relative-date"
      options["data-relative-date-datetime-value"] = DateTime.parse(article.published_at).iso8601
      options["title"] = formatted
    end
    content_tag :a, options do
      formatted
    end
  end

  # Determines whether the content should be hidden from search engines.
  # @return [Boolean] Returns true if the page should be hidden from search engines.
  def hide_from_search_engines?
    return true unless is_production?
    return false unless defined?(content)
    return true if content.draft
    !content.index_in_search_engines
  end

  # Finds articles most related to a given article.
  # @param article [Object] The reference article for finding related articles.
  # @param count [Integer] (Optional) The number of articles to return.
  # @return [Array<Object>] A list of articles sorted by relevance.
  def related_articles(article, count: 4)
    data.articles
      .reject { |a| a.path == article.path } # Exclude the current article
      .reject { |a| a.draft } # Exclude drafts
      .reject { |a| a.entry_type == 'Short' } # Exclude short posts
      .sort_by { |a| -relatedness_score(article, a) } # Sort by relatedness score, in descending order
      .take(count)
  end

  # Returns the most viewed articles based on analytics data.
  # @param count [Integer] (Optional) The number of articles to return.
  # @param exclude [Object] (Optional) An article to exclude from the results.
  # @return [Array<Object>] An array of the most viewed articles, up to the specified count.
  def most_viewed_articles(count: 4, exclude: nil)
    data.articles
      .reject { |a| a.path == exclude&.path }
      .reject { |a| a.draft }
      .reject { |a| a.entry_type == 'Short' }
      .sort { |a, b| b.metrics.all.pageviews <=> a.metrics.all.pageviews }
      .take(count)
  end

  # Returns the most trending articles on the site based on a "trending score".
  # @param count [Integer] (Optional) The number of articles to return.
  # @param exclude [Object] (Optional) An article to exclude from the results.
  # @return [Array<Object>] An array of the trending articles, up to the specified count.
  def trending_articles(count: 4, exclude: nil)
    data.articles
      .reject { |a| a.path == exclude&.path }
      .reject { |a| a.draft }
      .reject { |a| a.entry_type == 'Short' }
      .sort { |a, b| compare_by_trending_score(a, b) }
      .take(count)
  end

  # Compares two articles based on 1d, 7d, and all-time pageviews, in that order.
  # That is, the article with the most pageviews in the past day is considered first.
  # If the day's pageviews are equal, the pageviews for the past week is used as a tie breaker.
  # If they're still tied, then all-time pageviews are used as a final tie breaker.
  # @param a [Object] The first article to compare.
  # @param b [Object] The second article to compare.
  # @return [Integer] -1, 0, or 1, depending on the comparison.
  def compare_by_pageviews(a, b)
    day_pageviews_b = b.metrics[:"1d"].pageviews
    day_pageviews_a = a.metrics[:"1d"].pageviews

    if day_pageviews_b != day_pageviews_a
      day_pageviews_b <=> day_pageviews_a
    else
      week_pageviews_b = b.metrics[:"7d"].pageviews
      week_pageviews_a = a.metrics[:"7d"].pageviews

      if week_pageviews_b != week_pageviews_a
        week_pageviews_b <=> week_pageviews_a
      else
        b.metrics.all.pageviews <=> a.metrics.all.pageviews
      end
    end
  end

  # Compares two articles based on their trending scores and, if tied, their pageview metrics.
  # @param a [Object] The first article to compare.
  # @param b [Object] The second article to compare.
  # @return [Integer] -1, 0, or 1, depending on the comparison result.
  def compare_by_trending_score(a, b)
    score_b = trending_score(b)
    score_a = trending_score(a)

    if score_b != score_a
      score_b <=> score_a
    else
      compare_by_pageviews(a, b) # Fall back to pageviews if scores are tied
    end
  end

  # Calculates a "trending score" for an article based on the rate of change in traffic.
  # The score is determined by comparing the 1-day pageviews against the average pageviews
  # over the past week.
  # @param article [Object] The article for which to calculate the trending score.
  # @return [Float] The growth rate of the article's traffic. Returns 0 if there is no past traffic data.
  def trending_score(article)
    avg_pageviews_last_week = article.metrics[:"7d"].pageviews / 7.0
    return 0 if avg_pageviews_last_week.zero?

    (article.metrics[:"1d"].pageviews - avg_pageviews_last_week) / avg_pageviews_last_week
  end

  # Calculates an overall score of how related two articles are.
  # The score considers:
  # - Shared tags (more tags in common means they're more related)
  # - Title similarity (more similar titles are weighed more heavily)
  # - Recency (more recent articles are weighed more heavily)
  #
  # @param article [Object] The reference article.
  # @param candidate [Object] The article to evaluate for relatedness.
  # @return [Float] The relatedness score for the candidate article.
  def relatedness_score(article, candidate)
    tags_weight = ENV.fetch('RELATEDNESS_TAGS_WEIGHT', 1).to_i
    recency_weight = ENV.fetch('RELATEDNESS_RECENCY_WEIGHT', 1).to_i
    title_weight = ENV.fetch('RELATEDNESS_TITLE_WEIGHT', 1).to_i

    shared_tags = (candidate.contentful_metadata.tags.map(&:id) & article.contentful_metadata.tags.map(&:id)).size
    recency = recency_score(candidate)
    title_similarity = Text::WhiteSimilarity.new.similarity(sanitize(article.title), sanitize(candidate.title))

    (shared_tags * tags_weight) + (recency * recency_weight) + (title_similarity * title_weight)
  end

  # Calculates a recency score for an article based on its age.
  # The score decays exponentially as the article gets older.
  # @param article [Object] The article to evaluate.
  # @return [Float] A score between 0 and 1 based on how recently the article was published.
  def recency_score(article)
    days_old = ((Time.now - DateTime.parse(article.published_at)) / 1.day).to_i
    Math.exp((ENV.fetch('RECENCY_SCORE_DECAY_RATE', 0.1).to_f * -1) * days_old)
  end

  # Generates a JSON-LD schema string for an article, based on the provided content.
  # @param content [Object] An object containing the article's data.
  # @see https://developers.google.com/search/docs/appearance/structured-data/article
  # @return [String] A JSON-LD formatted string representing the article's schema.
  def article_schema(content)
    return if content.draft
    schema = {
      "@context": "https://schema.org",
      "@type": "Article",
      "headline": sanitize(content.title),
      "datePublished": DateTime.parse(content.published_at).iso8601,
      "dateModified": DateTime.parse(content.sys.published_at).iso8601,
      "author": { "@type": "Person", "name": content.author.name, "url": full_url("/author/#{content.author.slug}") }
    }
    if content&.cover_image&.url.present?
      schema["image"] = ["1000x1000", "1600x900", "1600x1200"].map do |s|
        w, h = s.split('x')
        params = { w: w, h: h, fit: 'cover' }
        cdn_image_url(content.cover_image.url, params)
      end
    end
    schema.to_json
  end

  # Turns a tag into a camelcased hashtag, e.g. "My Tag" => "#MyTag"
  # @param tag [String] The tag to convert.
  # @return [String] The camelcased hashtag.
  def camelcase_hashtag(tag)
    return if tag.blank?
    "##{tag.parameterize.split('-').map(&:capitalize).join}"
  end

  # Generates a Mastodon post for a given entry.
  # @param entry [Object] The entry to generate a Mastodon post for.
  # @return [String] The Mastodon post content.
  def mastodon_post(entry)
    body = []
    body << smartypants(sanitize(entry.summary.presence || entry.title.presence))
    body << full_url(entry.path)
    body << entry.contentful_metadata.tags.sort { |a, b| a.name <=> b.name }.map { |t| camelcase_hashtag(t.name) }.join(' ')
    body.reject(&:blank?).join("\n\n")
  end

  # Formats the reading time for an article.
  # @param article [Object] The article to calculate the reading time for.
  # @return [String] The formatted reading time.
  def reading_time(article)
    wpm = ENV.fetch('READING_TIME_WPM', 200).to_i
    plain_text = sanitize([article.intro, article.body].reject(&:blank?).join("\n\n"), escape_html_entities: true)
    word_count = plain_text.split(/\s+/).size
    minutes = (word_count / wpm.to_f).ceil
    formatted_time = if minutes <= 1
      "One-minute read"
    else
      "#{minute}-minute read"
    end
  end

  # Formats the number of pageviews for an article.
  # @param article [Object] The article to show the pageviews for.
  # @return [String] The formatted number of views.
  def article_views(article)
    return if article&.metrics&.all&.pageviews.blank?
    views = [1, article.metrics.all.pageviews].max
    times = views == 1 ? 'once' : "#{number_to_delimited(views)} times"
    "Viewed #{times}"
  end
end
