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
    if content.is_a?(Hash) && !content.isHomePage
      title << content.title
      title << "Page #{content.current_page}" if content&.current_page.to_i > 1
    elsif content.is_a?(String)
      title << content
    else
      title << data.site.metaTitle
    end
    title << data.site.metaTitle if include_site_name

    Sanitize.fragment(title.reject(&:blank?).uniq.join(separator)).strip
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
    if content.summary.present?
      content.summary
    else
      data.site.metaDescription
    end
  end

  # Determines whether the content should be hidden from search engines.
  # @param content [Object] The content object to evaluate.
  # @return [Boolean] Returns true if the content should not be indexed in search engines.
  def hide_from_search_engines?(content)
    return true if content.draft
    !content.indexInSearchEngines
  end

  # Generates the path for a specific page in a paginated series.
  # @param page [Integer] The page number for which to generate the path.
  # @return [String] The path for the given page in the pagination.
  def pagination_path(page:)
    if page == 1
      "/blog/index.html"
    else
      "/blog/page/#{page}/index.html"
    end
  end

  # Selects a specified number of articles related to a given article based on shared tags.
  # @param article [Object] The reference article for finding related articles.
  # @param count [Integer] (Optional) The number of related articles to return. Default is 4.
  # @return [Array<Object>] An array of articles related to the given article, up to the specified count.
  def related_articles(article, count: 4)
    tags = article.contentfulMetadata.tags.map(&:id)
    data.articles
      .reject { |a| a.path == article.path } # Reject the article itself
      .reject { |a| a.draft } # Reject drafts
      .reject { |a| a.entry_type == 'Short' } # Reject short posts
      .sort { |a,b| (b.contentfulMetadata.tags.map(&:id) & tags).size <=> (a.contentfulMetadata.tags.map(&:id) & tags).size } # Fake relevancy sorting by sorting by number of common tags
      .slice(0, count) # Slice the specified number of articles
  end

  # Retrieves a specified number of random articles, excluding drafts and short entries.
  # @param count [Integer] (Optional) The number of random articles to return. Default is 5.
  # @return [Array<Object>] An array of randomly selected articles, up to the specified count.
  def random_articles(count: 5)
    data.articles.reject { |a| a.draft || a.entry_type == 'Short' }.shuffle.slice(0, count)
  end

  # Retrieves a specified number of the most recent articles, excluding drafts and short entries.
  # @param count [Integer] (Optional) The number of recent articles to return. Default is 5.
  # @return [Array<Object>] An array of the most recent articles, up to the specified count.
  def recent_articles(count: 5)
    data.articles.reject { |a| a.draft || a.entry_type == 'Short' }.slice(0, count)
  end

  # Attempts to determine the time the website was most recently updated.
  # @return [DateTime] The latest date and time at which either a page, an article, or the site was updated.
  def site_updated_at
    [
      data.pages.reject { |p| p.draft || !p.indexInSearchEngines }.map { |p| DateTime.parse(p.sys.publishedAt) },
      data.articles.reject { |a| a.draft || !a.indexInSearchEngines }.map { |a| DateTime.parse(a.sys.publishedAt) },
      DateTime.parse(data.site.sys.publishedAt)
    ].flatten.max
  end
end
