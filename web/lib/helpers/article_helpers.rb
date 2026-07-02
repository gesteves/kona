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

  # Returns a permalink anchor tag for the article, with the date it was published as its text.
  # The publish-date Stimulus controller swaps in a live relative timestamp client-side for recent
  # articles (so it stays correct without a rebuild); the absolute date here is the no-JS fallback.
  # @param article [Object] The article.
  # @return [String] An <a> tag linking to the article, with the publish date as the text.
  def article_permalink_timestamp(article)
    published = DateTime.parse(article.published_at)
    options = {
      href: article.path,
      title: "Published at #{published.strftime('%-I:%M %p')}",
      "data-publish-date-target": "timestamp"
    }
    content_tag :a, options do
      published.strftime('%A, %B %-e, %Y')
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

  # Retrieves the articles to list in llms.txt: full articles only (no shorts), indexable, and
  # newest first (data.articles is already sorted by publish date, descending).
  # @param count [Integer] (Optional) The maximum number of articles to return. Default is 100.
  # @return [Array<Object>] An array of the most recent indexable full articles.
  def llms_articles(count: 100)
    data.articles
      .reject { |a| a.draft || !a.index_in_search_engines }
      .reject { |a| a.entry_type == 'Short' }
      .take(count)
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
      "inLanguage": "en-US",
      "isAccessibleForFree": true,
      "wordCount": article_word_count(content),
      "timeRequired": "PT#{reading_time_minutes(content)}M",
      # Reference the sitewide entity-graph nodes (partials/schema/_site) by @id rather than
      # duplicating them, so consumers resolve the author and publisher to a single entity each.
      "author": { "@id": schema_entity_id('person', path: '/about') },
      "publisher": { "@id": schema_entity_id('organization') },
      "isPartOf": { "@id": schema_entity_id('website') },
      "mainEntityOfPage": {
        "@type": "WebPage",
        "@id": canonical_url
      }
    }
    tags = Array(content.contentful_metadata&.tags)
    if tags.present?
      schema["keywords"] = tags.map(&:name)
      schema["articleSection"] = tags.first.name
    end
    if content&.cover_image&.url.present?
      schema["image"] = ["1000x1000", "1600x900", "1600x1200"].map do |s|
        w, h = s.split('x').map(&:to_i)
        {
          "@type": "ImageObject",
          "url": cdn_image_url(content.cover_image.url, { w: w, h: h, fit: 'cover' }),
          "width": w,
          "height": h
        }
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

  # Counts the words in an article's prose (intro + body, as plain text). Shared by the reading-time
  # estimate and the BlogPosting schema's wordCount. Memoized per entry — sanitizing the whole
  # article is expensive and this gets called several times per page (reading time + schema).
  # @param article [Object] The article.
  # @return [Integer] The number of words.
  def article_word_count(article)
    @article_word_counts ||= {}
    key = article.sys&.id
    return compute_article_word_count(article) if key.blank?

    @article_word_counts[key] ||= compute_article_word_count(article)
  end

  # @see #article_word_count
  def compute_article_word_count(article)
    plain_text = sanitize([article.intro, article.body].reject(&:blank?).join("\n\n"), escape_html_entities: true)
    plain_text.split(/\s+/).size
  end

  # The estimated reading time for an article, in whole minutes (rounded up).
  # @param article [Object] The article.
  # @return [Integer] Reading time in minutes.
  def reading_time_minutes(article)
    wpm = ENV.fetch('READING_TIME_WPM', 200).to_i
    (article_word_count(article) / wpm.to_f).ceil
  end

  # Formats the reading time for an article.
  # @param article [Object] The article to calculate the reading time for.
  # @return [String] The formatted reading time.
  def reading_time(article)
    minutes = reading_time_minutes(article)
    # \b so e.g. "eighty" or "eight hundred" doesn't get "An".
    indefinite_article = minutes.humanize.match?(/^(eight|eleven|eighteen)\b/i) ? 'An' : 'A'
    "#{indefinite_article} #{minutes}-minute read"
  end

  # Finds related race reports from the same event as the current article. Memoized — the
  # article template consults this once to pick a section and the partial again to render it.
  # @param article [Object] The current article to find race reports for.
  # @param count [Integer] (Optional) The number of race reports to return.
  # @return [Array<Object>] A list of race reports from the same event, sorted by publication date in reverse chronological order.
  def related_race_reports(article, count: 4)
    return [] unless article.event&.sys&.id

    @related_race_reports ||= {}
    @related_race_reports[[article.slug, count]] ||= data.articles
      .select { |a| a.event&.sys&.id == article.event.sys.id }
      .reject { |a| a.slug == article.slug }
      .reject { |a| a.draft }
      .reject { |a| a.entry_type == 'Short' }
      .sort_by { |a| -DateTime.parse(a.published_at).to_i }
      .take(count)
  end
end
