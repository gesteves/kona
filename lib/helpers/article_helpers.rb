require 'text'

module ArticleHelpers
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

  # Returns the canonical URL for the current content object or the current page.
  # @return [String] A canonical URL.
  def canonical_url
    return content.canonical_url if defined?(content) && content&.canonical_url.present?
    full_url(current_page.url)
  end

  # Retrieves a specified number of the most recent articles, excluding drafts and short entries.
  # @param count [Integer] (Optional) The number of recent articles to return.
  # @param exclude [Object] (Optional) An article to exclude from the results.
  # @return [Array<Object>] An array of the most recent articles, up to the specified count.
  def recent_articles(count: 4, exclude: nil)
    data.articles
      .reject { |a| a.path == exclude&.path } # Exclude the given article, if applicable
      .reject { |a| a.draft }                 # Exclude drafts
      .reject { |a| a.entry_type == 'Short' } # Exclude short posts
      .take(count)
  end

  # Retrieves a specified number of the most recent articles for the RSS feed, excluding drafts.
  # @param count [Integer] (Optional) The number of recent articles to return. Default is 100.
  # @return [Array<Object>] An array of the most recent articles, up to the specified count.
  def feed_articles(count: 100)
    data.articles.reject { |a| a.draft }.take(count)
  end

  # Returns the articles most relevant to the given article.
  # @param article [Object] The reference article for finding related articles.
  # @param count [Integer] (Optional) The number of articles to return.
  # @return [Array<Object>] A list of articles sorted by relevance.
  def related_articles(article, count: 4)
    data.articles
      .reject { |a| a.path == article.path }          # Exclude the current article
      .reject { |a| a.draft }                         # Exclude drafts
      .reject { |a| a.entry_type == 'Short' }         # Exclude short posts
      .sort_by { |a| -relevance_score(article, a) }   # Sort by relevance score, in descending order
      .take(count)
  end

  # Returns the most viewed articles based on analytics data.
  # @param count [Integer] (Optional) The number of articles to return.
  # @param exclude [Object] (Optional) An article to exclude from the results.
  # @return [Array<Object>] An array of the most viewed articles, up to the specified count.
  def most_viewed_articles(count: 4, exclude: nil)
    data.articles
      .reject { |a| a.path == exclude&.path } # Exclude the given article, if applicable
      .reject { |a| a.draft }                 # Exclude drafts
      .reject { |a| a.entry_type == 'Short' } # Exclude short posts
      .sort { |a, b| b.metrics.all.pageviews <=> a.metrics.all.pageviews } # Sort by all-time pageviews in descending order
      .take(count)
  end

  # Returns the articles that are "trending", i.e. getting a surge of traffic.
  # @param count [Integer] (Optional) The number of articles to return.
  # @param exclude [Object] (Optional) An article to exclude from the results.
  # @return [Array<Object>] An array of the trending articles, up to the specified count.
  def trending_articles(count: 4, exclude: nil)
    data.articles
      .reject { |a| a.path == exclude&.path } # Exclude the given article, if applicable
      .reject { |a| a.draft }                 # Exclude drafts
      .reject { |a| a.entry_type == 'Short' } # Exclude short posts
      .sort_by { |a| -trending_score(a) }     # Sort by trending score, in descending order
      .take(count)
  end

  # Calculates the growth rate for an article, comparing the pageviews in the past day
  # to the average pageviews in the past week.
  # @param article [Object] The article for which to calculate the growth rate.
  # @return [Float] The growth rate. Returns 0 if there are no past pageviews.
  def pageview_growth_rate(article)
    avg_pageviews_last_week = article.metrics[:"7d"].pageviews / 7.0
    return 0 if avg_pageviews_last_week.zero?

    (article.metrics[:"1d"].pageviews - avg_pageviews_last_week) / avg_pageviews_last_week
  end

  # Normalizes the growth rate of an article to a "trending" score between 0 and 1.
  # e.g. the article with the highest growth rate in the past day is the most "trending" one,
  # with a score of 1.
  # (idk, just making things up.)
  # @param article [Object] The article for which to calculate the trending score.
  # @return [Float] The trending score, between 0 and 1.
  def trending_score(article)
    # Calculate max growth rates among all articles
    max_growth_rate = data.articles
      .reject { |a| a.draft }                 # Exclude drafts
      .reject { |a| a.entry_type == 'Short' } # Exclude short posts
      .map { |a| pageview_growth_rate(a) }
      .max

    # Avoid division by zero
    return 0 if max_growth_rate.zero?

    # Normalize the article's growth rate
    article_growth_rate = pageview_growth_rate(article)
    article_growth_rate / max_growth_rate
  end

  # Calculates an overall similarity score between two articles.
  # The score is normalized to be between 0 and 1 and considers:
  # - Proportion of shared tags (articles with lots of tags in common are probably similar)
  # - Similarity of the titles (articles with similar titles are probably similar)
  # @param article [Object] The reference article.
  # @param candidate [Object] The article to evaluate for similarity.
  # @return [Float] The similarity score between 0 and 1.
  def similarity_score(article, candidate)
    tags_weight = ENV.fetch('SIMILARITY_TAGS_WEIGHT', 1).to_f
    title_weight = ENV.fetch('SIMILARITY_TITLE_WEIGHT', 1).to_f

    # Tags score is the percentage of tags in common
    total_tags = article.contentful_metadata.tags.map(&:id).size.to_f
    shared_tags = (candidate.contentful_metadata.tags.map(&:id) & article.contentful_metadata.tags.map(&:id)).size
    tags_score = total_tags.zero? ? 0 : (shared_tags / total_tags)

    # Title score uses Text::WhiteSimilarity to score how similar their titles are
    white = Text::WhiteSimilarity.new
    title_score = white.similarity(sanitize(article.title), sanitize(candidate.title))

    (tags_score * tags_weight) + (title_score * title_weight)
  end

  # Calculates a relevance score by adding up similarity_score, recency_score, and trending_score.
  # Assumes that articles that are similar, recent, and trending are relevant to the given article.
  # @param article [Object] The reference article.
  # @param candidate [Object] The article to evaluate for relevance.
  # @return [Float] The relevance score between 0 and 1.
  def relevance_score(article, candidate)
    similarity_weight = ENV.fetch('RELEVANCE_SIMILARITY_WEIGHT', 1).to_f
    recency_weight = ENV.fetch('RELEVANCE_RECENCY_WEIGHT', 1).to_f
    trending_weight = ENV.fetch('RELEVANCE_TRENDING_WEIGHT', 1).to_f

    similarity = similarity_score(article, candidate)
    recency = recency_score(candidate)
    trending = trending_score(candidate)

    (similarity * similarity_weight) + (recency * recency_weight) + (trending * trending_weight)
  end

  # Calculates a recency score for an article based on its age.
  # The score decays exponentially as the article gets older.
  # @param article [Object] The article to evaluate.
  # @return [Float] A score between 0 and 1 based on how recently the article was published.
  def recency_score(article)
    days_old = ((Time.now - DateTime.parse(article.published_at)) / 1.day).to_i
    Math.exp((ENV.fetch('RECENCY_SCORE_DECAY_RATE', 0.1).to_f.abs * -1) * days_old)
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
    "A #{minutes}-minute read"
  end

  # Formats the number of pageviews for an article.
  # @param article [Object] The article to show the pageviews for.
  # @return [String] The formatted number of views.
  def article_views(article)
    # Add one because if someone is seeing this number, by definition it has gone up by one.
    views = article&.metrics&.all&.pageviews.to_i + 1
    times = case views
    when 1
      "once"
    when 2
      "twice"
    when 69
      "69 times (nice)"
    else
      "#{number_to_delimited(views)} times"
    end
    "Viewed #{times}"
  end

  def plausible_url(article, period: "all")
    return unless ENV['PLAUSIBLE_SITE_ID'].present?
    "https://plausible.io/#{ENV['PLAUSIBLE_SITE_ID']}?period=#{period}&filters=((is,page,(#{article.path.gsub(/\/index.html$/, '/')})))"
  end
end
