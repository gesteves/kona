module SiteHelpers
  def atom_tag(url, date = nil)
    tag = url.gsub(/^http(s)?:\/\//, '').gsub('#', '/').split('/')
    tag[0] = "tag:#{tag[0]},#{date.strftime('%Y-%m-%d')}:"
    tag.join('/')
  end

  def page_title(content)
    if content.is_a? Hash
      if content&.current_page.to_i > 1
        [content.title, "Page #{content.current_page}"]
      elsif content.title.present? && content.isHomePage.blank?
        content.title
      end
    elsif content.is_a? String
      content
    else
      data.site.metaTitle
    end
  end

  def title_tag(content, separator: ' · ')
    title = page_title(content)
    strip_tags(smartypants([title, data.site.metaTitle].flatten.reject(&:blank?).uniq.join(separator)))
  end

  def og_title(content, separator: ' · ')
    title = page_title(content)
    strip_tags(smartypants([title].flatten.reject(&:blank?).uniq.join(separator)))
  end

  def content_summary(content)
    if content.summary.present?
      content.summary
    else
      data.site.metaDescription
    end
  end

  def hide_from_search_engines?(content)
    return true if content.draft
    !content.indexInSearchEngines
  end

  def pagination_path(page:)
    if page == 1
      "/blog/index.html"
    else
      "/blog/page/#{page}/index.html"
    end
  end

  def related_articles(article, count: 4)
    tags = article.contentfulMetadata.tags.map(&:id)
    data.articles
      .reject { |a| a.path == article.path } # Reject the article itself
      .reject { |a| a.draft } # Reject drafts
      .reject { |a| a.entry_type == 'Short' } # Reject short posts
      .sort { |a,b| (b.contentfulMetadata.tags.map(&:id) & tags).size <=> (a.contentfulMetadata.tags.map(&:id) & tags).size } # Fake relevancy sorting by sorting by number of common tags
      .slice(0, count) # Slice the specified number of articles
  end

  def random_articles(count: 5)
    data.articles.reject { |a| a.draft || a.entry_type == 'Short' }.shuffle.slice(0, count)
  end

  def recent_articles(count: 5)
    data.articles.reject { |a| a.draft || a.entry_type == 'Short' }.slice(0, count)
  end

  def site_updated_at
    [
      data.pages.reject { |p| p.draft || !p.indexInSearchEngines }.map { |p| DateTime.parse(p.sys.publishedAt) },
      data.articles.reject { |a| a.draft || !a.indexInSearchEngines }.map { |a| DateTime.parse(a.sys.publishedAt) },
      DateTime.parse(data.site.sys.publishedAt)
    ].flatten.max
  end
end
