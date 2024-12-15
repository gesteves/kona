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

  # Determines if the article was published today the current timezone.
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

  # Selects a specified number of articles related to a given article based on shared tags.
  # @param article [Object] The reference article for finding related articles.
  # @param count [Integer] (Optional) The number of related articles to return. Default is 4.
  # @return [Array<Object>] An array of articles related to the given article, up to the specified count.
  def related_articles(article, count: 4)
    tags = article.contentful_metadata.tags.map(&:id)
    data.articles
      .reject { |a| a.path == article.path } # Reject the article itself
      .reject { |a| a.draft } # Reject drafts
      .reject { |a| a.entry_type == 'Short' } # Reject short posts
      .sort { |a,b| (b.contentful_metadata.tags.map(&:id) & tags).size <=> (a.contentful_metadata.tags.map(&:id) & tags).size } # Fake relevancy sorting by sorting by number of common tags
      .take(count) # Take the specified number of articles
  end

  # Returns the most popular articles based on Plausible analytics data.
  # @param count [Integer] (Optional) The number of popular articles to return. Default is 4.
  # @param exclude [Object] (Optional) An article to exclude from the results.
  # @return [Array<Object>] An array of the most popular articles, up to the specified count.
  def most_read_articles(count: 4, exclude: nil)
    data.articles
      .reject { |a| a.path == exclude&.path }
      .reject { |a| a.draft }
      .reject { |a| a.entry_type == 'Short' }
      .sort { |a, b| b.metrics.all.pageviews <=> a.metrics.all.pageviews }
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

  # Turns a tag into a camelcased hashtag, e.g. #my-tag => #MyTag
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
end
