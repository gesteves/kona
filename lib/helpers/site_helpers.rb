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
    elsif content.entry_type == 'Short'
      content.intro
    elsif content.intro.present?
      content.intro&.truncate(200)
    else
      data.site.meta_description
    end
    sanitize(summary)
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
    "#{data.articles.reject(&:draft).map { |a| DateTime.parse(a.published_at) }.min.strftime('%Y')}–#{current_time.strftime('%Y')}"
  end

  # Returns the title for the RSS feed, based off the site's meta title.
  # @return [String] The title for the feed.
  def feed_title
    data.site.meta_title.split(':').first.strip
  end

  # Returns the subtitle for the RSS feed, based off the site's meta title.
  # @return [String] The subtitle for the feed.
  def feed_subtitle
    subtitle = data.site.meta_title.split(':').last.strip
    return if subtitle == feed_title
    subtitle
  end

  # Returns the markup for a social media link.
  # @param title [String] The title of the social media platform.
  # @param destination [String] The URL to the social media profile.
  # @param css_class [String] The CSS class to apply to the link.
  # @param open_in_new_tab [Boolean] Whether to open the link in a new tab.
  # @return [String] An anchor element with an SVG icon.
  def social_media_link(title:, destination:, css_class: nil, open_in_new_tab: true)
    icon = if title.downcase == 'feed'
      icon_svg("classic", "solid", "rss")
    else
      icon_svg("classic", "brands", title.downcase)
    end

    icon = icon_svg("classic", "solid", "link") if icon.blank?

    options = if title.downcase == 'feed'
      {
        "title": "Subscribe to the feed",
        "data-controller": "clipboard",
        "data-action": "click->clipboard#preventDefault",
        "data-clipboard-success-message-value": "The link to the feed has been copied to your clipboard."
      }
    else
      {
        "title": "Follow on #{title}"
      }
    end
    options["rel"] = open_in_new_tab ? "me noopener" : "me"
    options["target"] = "_blank" if open_in_new_tab
    options["class"] = css_class if css_class.present?
    options["href"] = destination

    content_tag :a, options do
      icon
    end
  end

  # Formats the text at the very bottom of the footer.
  # @return [String] A string of HTML.
  def footer_text
    text = "© #{copyright_years} #{data.site.copyright}"
    markdown_to_html(text)
  end

  # Returns the number of entries tagged with a specific tag.
  # @param tag_name [String] The name of the tag to count entries for.
  # @return [Integer] The number of entries tagged with the specified tag.
  def tag_entry_count(tag_name)
    tag = data.tags.find { |t| t&.tag&.name == tag_name }
    return 0 if tag.blank?
    tag.pages.map { |t| t.items }.flatten.uniq.size
  end

  # Checks if Plausible analytics is properly installed by verifying required redirects exist.
  # @return [Boolean] True if both required Plausible redirects are present in data/redirects.json
  def is_plausible_installed?
    return false unless data.redirects.present?
    
    required_redirects = [
      { from: '/js/script.js', status: 200 },
      { from: '/api/event', status: 200 }
    ]
    
    required_redirects.all? do |required|
      data.redirects.any? do |redirect|
        redirect['from'] == required[:from] && redirect['status'] == required[:status]
      end
    end
  end

  # Generates a JSON-LD schema string for the organization, based on the site data.
  # @see https://developers.google.com/search/docs/appearance/structured-data/organization
  # @return [String] A JSON-LD formatted string representing the organization's schema.
  def organization_schema
    schema = {
      "@context": "https://schema.org",
      "@type": "Organization",
      "name": sanitize(data.site.title),
      "url": full_url('/')
    }

    if data.site.logo.present?
      schema["logo"] = site_icon_url(w: 180)
    end

    if data.site.socials_collection.items.present?
      same_as_urls = data.site.socials_collection.items
        .reject { |s| s.title.downcase == 'feed' }
        .map { |s| s.destination }
      
      schema["sameAs"] = same_as_urls if same_as_urls.present?
    end

    schema.to_json
  end
end
