require 'sanitize'

module SiteHelpers
  # Generates an Atom-compliant tag URI from a URL and date.
  # @param url [String] The URL to be converted.
  # @param date [Date, Time] The date for the tag.
  # @return [String] The Atom tag URI.
  def atom_tag(url, date)
    tag = url.gsub(/^http(s)?:\/\//, '').gsub('#', '/').split('/')
    tag[0] = "tag:#{tag[0]},#{date.strftime('%Y-%m-%d')}:"
    tag.join('/')
  end

  # Generates a formatted page title based on the provided content.
  # @param content [Hash, String] The content to generate the title from.
  #   If a Hash, expects :title and :current_page keys for pagination.
  #   If a String, uses directly as the title content.
  # @param include_site_name [Boolean] Whether to append the site's title to the generated title.
  # @param separator [String] The separator used between title segments.
  # @return [String] The sanitized and formatted page title.
  def page_title(content, include_site_name: false, separator: ' · ')
    title = []
    if content.is_a?(Hash) && !content.is_home_page
      title << content.title
      title << "Page #{content.current_page}" if content&.current_page.to_i > 1
    elsif content.is_a?(String)
      title << content
    else
      title << data.site.meta_title
    end
    title << data.site.meta_title if include_site_name

    sanitize(title.reject(&:blank?).uniq.join(separator))
  end

  # Wraps the generated page title within a title HTML tag.
  # @param content [Hash, String] The content to generate the title from.
  # @return [String] An HTML title tag with the generated page title.
  def title_tag(content)
    content_tag :title do
      page_title(content, include_site_name: true)
    end
  end

  # Retrieves a summary of the content, falling back to the site's meta description if not present.
  # @param content [Object] The content object which may contain a summary.
  # @return [String] The content summary or the site's meta description.
  def content_summary(content)
    summary = if content.summary.present?
      content.summary
    else
      data.site.meta_description
    end
    sanitize(summary)
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

  # Retrieves a specified number of random articles, excluding drafts and short entries.
  # @param count [Integer] (Optional) The number of random articles to return. Default is 5.
  # @return [Array<Object>] An array of randomly selected articles, up to the specified count.
  def random_articles(count: 5)
    data.articles.reject { |a| a.draft || a.entry_type == 'Short' }.shuffle.take(count)
  end

  # Retrieves a specified number of the most recent articles, excluding drafts and short entries.
  # @param count [Integer] (Optional) The number of recent articles to return. Default is 5.
  # @return [Array<Object>] An array of the most recent articles, up to the specified count.
  def recent_articles(count: 5)
    data.articles.reject { |a| a.draft || a.entry_type == 'Short' }.take(count)
  end

  # Attempts to determine the time the website was most recently updated.
  # @return [DateTime] The latest date and time at which either a page, an article, or the site was updated.
  def site_updated_at
    [
      data.pages.reject { |p| p.draft || !p.index_in_search_engines }.map { |p| DateTime.parse(p.sys.published_at) },
      data.articles.reject { |a| a.draft || !a.index_in_search_engines }.map { |a| DateTime.parse(a.sys.published_at) },
      DateTime.parse(data.site.sys.published_at)
    ].flatten.max
  end

  # Returns a range of years, from the year the earliest article was published to the current year.
  # @return [String] A range of years, like 2006-2024.
  def copyright_years
    "#{data.articles.reject(&:draft).map { |a| DateTime.parse(a.published_at) }.min.strftime('%Y')}–#{Time.current.in_time_zone(location_time_zone).strftime('%Y')}"
  end
end
