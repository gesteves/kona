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

  # Determines if the article was published in the past week in the current timezone.
  # @param article [Object] The article.
  # @return [Boolean] If the article was published in the past week.
  def published_in_the_past_week?(article)
    article_date = Time.parse(article.published_at).in_time_zone(location_time_zone)
    article_date.to_date >= 1.week.ago.to_date
  end

  # Determines if the article is "new".
  # A full length article is "new" if it was published less than a week ago.
  # A short article is "new" if it was published today.
  # @param article [Object] The article.
  # @return [Boolean] If the article is considered new.
  def new_article?(article)
    return false if article.draft
    if article.entry_type == 'Short'
      published_today?(article)
    else
      published_in_the_past_week?(article)
    end
  end

  # Returns a permalink anchor tag for the article, with the date it was published.
  # If the article was published today, includes attributes to render the date as a relative timestamp.
  # @param article [Object] The article.
  # @return [String] An <a> tag linking to the article, with a relative or absolute date as the text.
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
      DateTime.parse(article.published_at).strftime('%A, %B %-e, %Y')
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
    # Get race reports that will be shown in the race reports section
    race_report_slugs = related_race_reports(article).map(&:slug)

    data.articles
      .reject { |a| a.path == article.path }             # Exclude the current article
      .reject { |a| a.draft }                            # Exclude drafts
      .reject { |a| a.entry_type == 'Short' }            # Exclude short posts
      .reject { |a| race_report_slugs.include?(a.slug) } # Exclude race reports shown in race reports section
      .sort_by { |a| -relevance_score(article, a) }      # Sort by relevance score, in descending order
      .take(count)
  end

  # Calculates an overall similarity score between two articles.
  # The score is normalized to be between 0 and 1 and considers:
  # - Proportion of shared tags (articles with lots of tags in common are probably similar)
  # - Similarity of the titles (articles with similar titles are probably similar)
  # @param article [Object] The reference article.
  # @param candidate [Object] The article to evaluate for similarity.
  # @return [Float] The similarity score.
  def similarity_score(article, candidate)
    tags_weight = ENV.fetch('SIMILARITY_SCORE_TAGS_WEIGHT', 1).to_f
    title_weight = ENV.fetch('SIMILARITY_SCORE_TITLE_WEIGHT', 1).to_f

    # Tags score is the percentage of tags in common
    total_tags = article.contentful_metadata.tags.map(&:id).size.to_f
    shared_tags = (candidate.contentful_metadata.tags.map(&:id) & article.contentful_metadata.tags.map(&:id)).size
    tags_score = total_tags.zero? ? 0 : (shared_tags / total_tags)

    # Title score uses Text::WhiteSimilarity to score how similar their titles are
    white = Text::WhiteSimilarity.new
    title_score = white.similarity(sanitize(article.title), sanitize(candidate.title))

    (tags_score * tags_weight) + (title_score * title_weight)
  end

  # Calculates a relevance score by adding up similarity_score and recency_score.
  # Assumes that articles that are similar and recent are relevant to the given article.
  # @param article [Object] The reference article.
  # @param candidate [Object] The article to evaluate for relevance.
  # @return [Float] The relevance score between 0 and 1.
  def relevance_score(article, candidate)
    similarity_weight = ENV.fetch('RELEVANCE_SCORE_SIMILARITY_WEIGHT', 1).to_f
    recency_weight = ENV.fetch('RELEVANCE_SCORE_RECENCY_WEIGHT', 1).to_f

    similarity = similarity_score(article, candidate)
    recency = recency_score(candidate)

    (similarity * similarity_weight) + (recency * recency_weight)
  end

  # Calculates a recency score for an article based on its age.
  # The score decays exponentially as the article gets older.
  # @param article [Object] The article to evaluate.
  # @return [Float] A score between 0 and 1 based on how recently the article was published.
  def recency_score(article)
    Math.exp((ENV.fetch('RECENCY_SCORE_DECAY_RATE', 0.1).to_f.abs * -1) * days_since_published(article))
  end

  # Generates a JSON-LD schema string for an article, based on the provided content.
  # @param content [Object] An object containing the article's data.
  # @see https://developers.google.com/search/docs/appearance/structured-data/article
  # @return [String] A JSON-LD formatted string representing the article's schema.
  def article_schema(content)
    return if content.draft
    schema = {
      "@context": "https://schema.org",
      "@type": "BlogPosting",
      "headline": sanitize(content.title),
      "description": sanitize(content_summary(content)),
      "datePublished": DateTime.parse(content.published_at).iso8601,
      "dateModified": DateTime.parse(content.sys.published_at).iso8601,
      "author": {
        "@type": "Person",
        "name": content.author.name,
        "url": full_url("/author/#{content.author.slug}")
      },
      "publisher": {
        "@type": "Organization",
        "name": data.site.title
      }.tap do |publisher|
        if data.site.logo.present?
          publisher["logo"] = {
            "@type": "ImageObject",
            "url": site_icon_url(w: 180)
          }
        end
      end,
      "mainEntityOfPage": {
        "@type": "WebPage",
        "@id": canonical_url
      }
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

  # Generates a JSON-LD schema string for breadcrumb navigation, based on the provided content.
  # @param content [Object] An object containing the article's data.
  # @see https://developers.google.com/search/docs/appearance/structured-data/breadcrumb
  # @return [String] A JSON-LD formatted string representing the breadcrumb schema.
  def breadcrumb_schema(content)
    return if content.draft || content.entry_type != 'Article'
    
    schema = {
      "@context": "https://schema.org",
      "@type": "BreadcrumbList",
      "itemListElement": [
        {
          "@type": "ListItem",
          "position": 1,
          "name": "Home",
          "item": full_url('/')
        },
        {
          "@type": "ListItem",
          "position": 2,
          "name": "Blog",
          "item": full_url('/blog')
        },
        {
          "@type": "ListItem",
          "position": 3,
          "name": sanitize(content.title),
          "item": canonical_url
        }
      ]
    }
    
    schema.to_json
  end

  # Turns a tag into a camelcased hashtag, e.g. "My Tag" => "#MyTag"
  # @param tag [String] The tag to convert.
  # @return [String] The camelcased hashtag.
  def camelcase_hashtag(tag)
    return if tag.blank?
    "##{tag.parameterize.split('-').map(&:capitalize).join}"
  end

  # Generates a social media post for a given entry.
  # @param entry [Object] The entry to generate a social media post for.
  # @return [String] The social media post content.
  def social_media_post(entry)
    content = if entry.social_media_summary.present?
      entry.social_media_summary
    elsif entry.summary.present?
      entry.summary
    else
      entry.title
    end
    smartypants(sanitize(content))
  end

  # Formats the reading time for an article.
  # @param article [Object] The article to calculate the reading time for.
  # @return [String] The formatted reading time.
  def reading_time(article)
    wpm = ENV.fetch('READING_TIME_WPM', 200).to_i
    plain_text = sanitize([article.intro, article.body].reject(&:blank?).join("\n\n"), escape_html_entities: true)
    word_count = plain_text.split(/\s+/).size
    minutes = (word_count / wpm.to_f).ceil
    article = minutes.humanize.match?(/^(eight|eleven|eighteen)/i) ? 'An' : 'A'
    "#{article} #{minutes}-minute read"
  end

  # Calculates the number of days since an article was published.
  # @param article [Object] The article to calculate the days since published for.
  # @return [Integer] The number of days since the article was published.
  def days_since_published(article)
    ((Time.now - DateTime.parse(article.published_at)) / 1.day).ceil
  end

  # Finds related race reports from the same event as the current article.
  # @param article [Object] The current article to find race reports for.
  # @param count [Integer] (Optional) The number of race reports to return.
  # @return [Array<Object>] A list of race reports from the same event, sorted by publication date in reverse chronological order.
  def related_race_reports(article, count: 5)
    return [] unless article.event&.sys&.id

    # Find all articles that are linked to the same event
    race_reports = data.articles
      .select { |a| a.event&.sys&.id == article.event.sys.id }
      .reject { |a| a.slug == article.slug }
      .reject { |a| a.draft }
      .reject { |a| a.entry_type == 'Short' }
      .sort_by { |a| -DateTime.parse(a.published_at).to_i }
      .take(count)

    race_reports
  end
end
