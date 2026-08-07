require 'sanitize'

module SiteHelpers
  # The public Cloudflare Turnstile sitekey for the contact form. Blank when unset, in which
  # case the widget isn't rendered and the api skips verification.
  # @return [String, nil]
  def turnstile_site_key
    ENV['TURNSTILE_SITE_KEY']
  end

  # The IANA timezone the site's dates are reckoned in — the owner's location, so "published
  # today", the clock-vs-calendar icon and the "New" badge flip at the same instant for every
  # reader instead of in each reader's own zone.
  # @return [String, nil] Blank when unset, which leaves the publish-date controller on the
  #   reader's browser timezone.
  def site_time_zone
    ENV['TIME_ZONE'].presence
  end

  # Generates an Atom-compliant tag URI from a URL and date.
  # @param url [String] The URL to be converted.
  # @param date [Date, Time] The date for the tag.
  # @return [String] The Atom tag URI.
  def atom_tag(url, date)
    tag = url.gsub(/^http(s)?:\/\//, '').gsub('#', '/').split('/')
    tag[0] = "tag:#{tag[0]},#{date.strftime('%Y-%m-%d')}:"
    tag.join('/')
  end

  # Builds the page title.
  # @param content [Hash, String] A content object (uses its :title) or a literal title string.
  # @param include_site_name [Boolean] Whether to append the site's title.
  # @param separator [String] Separator between title segments.
  # @return [String] The sanitized title.
  def page_title(content, include_site_name: false, separator: ' · ')
    title = []
    if content.is_a?(Hash) && !content.is_home_page
      title << content.title
    elsif content.is_a?(String)
      title << content
    else
      title << data.site.meta_title
    end
    title << data.site.meta_title if include_site_name

    sanitize(title.reject(&:blank?).uniq.join(separator))
  end

  # @param content [Hash, String] A content object or a literal title string.
  # @return [String] A <title> tag containing the page title and the site name.
  def title_tag(content)
    content_tag :title do
      page_title(content, include_site_name: true)
    end
  end

  # Renders a runtime widget's placeholder partial, wired to the endpoint the live-update
  # controller fetches on connect.
  # Don't pair these with <link rel="preload" as="fetch">: widget fragments are served
  # `max-age=0` with no validator, so a preloaded copy is stale on arrival and the controller's
  # fetch issues a second full request rather than reusing it.
  # @param name [String] The partial's basename under partials/placeholders/.
  # @param url [String] The same-origin widget endpoint, passed to the partial as `url`.
  # @return [String] The rendered placeholder.
  def render_widget(name, url)
    partial "partials/placeholders/#{name}", locals: { url: url }
  end

  # The proxied `content` object for the current page, read from page metadata since helpers
  # can't see template locals.
  # @return [Object, nil]
  def page_content
    locals = current_page.metadata[:locals]
    locals && locals[:content]
  end

  # The object driving the page's <title> and og:title: the proxied content object, else the
  # frontmatter title.
  # @return [Object, String, nil]
  def meta_title_source
    page_content || current_page.data.title.presence
  end

  # The page's meta/og description: the content summary, else the frontmatter summary.
  # @return [String, nil]
  def meta_description
    return content_summary(page_content) if page_content
    current_page.data.summary.presence
  end

  # The attributes a live-update placeholder's outer element carries. Interpolate inside its
  # opening tag.
  # The api fragment that replaces it repeats all of these except the placeholder flag — see the
  # web↔api contract in the root CLAUDE.md.
  # @param url [String] The same-origin widget endpoint.
  # @return [String] HTML attributes.
  def live_update_attrs(url)
    # url is always an app-generated same-origin path, never user input, so it needs no escaping.
    %(data-controller="live-update" data-live-update-url-value="#{url}" data-live-update-placeholder-value="true" data-action="visibilitychange@document->live-update#handleVisibilityChange").html_safe
  end

  # @param content [Object] A content object.
  # @return [String] Its summary, intro, or the site's meta description, whichever exists first.
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

  # @return [DateTime] The most recent publish time across pages, articles, and the site entry.
  def site_updated_at
    [
      indexable_pages.map { |p| DateTime.parse(p.sys.published_at) },
      indexable_articles.map { |a| DateTime.parse(a.sys.published_at) },
      DateTime.parse(data.site.sys.published_at)
    ].flatten.max
  end

  # The year of the earliest non-draft article, memoized since it renders in every page's footer
  # and each computation parses every article's publish date.
  # @return [String] A four-digit year.
  def copyright_start_year
    memoize_by_collection(:copyright_start_year, data.articles) do
      earliest = published_articles.map { |a| published_datetime(a) }.min
      earliest.nil? ? Time.current.year.to_s : earliest.strftime('%Y')
    end
  end

  # @return [String] The copyright year range, e.g. "2006–2024".
  def copyright_years
    "#{copyright_start_year}–#{Time.current.year}"
  end

  # The Atom feeds to advertise in <head>: the main site feed, plus the tag's feed on an archive
  # page or every one of the article's tags' feeds on a post.
  # @return [Array<Hash>] Entries of { href:, title: }.
  def alternate_feed_links
    links = [{ href: full_url('/feed.xml'), title: sanitize(data.site.meta_title) }]
    pc = page_content
    tags = if pc.nil?
      []
    elsif pc.template == '/tag.html' && pc.tag_id
      node = taxonomy_index[pc.tag_id] # the tag itself
      node ? [node] : []
    elsif published_post?(pc)
      Array(pc.contentful_metadata&.tags).map { |t| { name: t.name, path: t.path } }
    else
      []
    end
    tags.each do |t|
      links << { href: full_url("#{t[:path]}feed.xml"), title: sanitize("#{feed_title}: #{t[:name]}") }
    end
    links
  end

  # @return [String] The feed title, taken from the site's meta title.
  def feed_title
    data.site.meta_title.split(':', 2).first.strip
  end

  # @return [String, nil] The feed subtitle, or nil when the meta title has no second half.
  def feed_subtitle
    subtitle = data.site.meta_title.split(':', 2).last.strip
    return if subtitle == feed_title
    subtitle
  end

  # Attributes that make a feed link copy its URL to the clipboard instead of navigating. Also
  # used by MarkupHelpers#copy_feed_links for feed links inside rendered bodies.
  FEED_CLIPBOARD_ATTRS = {
    "data-controller": "clipboard",
    "data-action": "click->clipboard#copy",
    "data-clipboard-success-message-value": "The link to the feed has been copied to your clipboard."
  }.freeze

  # Builds a social media link. A "Feed" link copies its URL instead of navigating.
  # @param title [String] The platform's name.
  # @param destination [String] The profile URL.
  # @param css_class [String] A CSS class for the link.
  # @param open_in_new_tab [Boolean] Whether to open the link in a new tab.
  # @return [String] An anchor element wrapping an SVG icon.
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
        "aria-label": "Subscribe to the feed",
        **FEED_CLIPBOARD_ATTRS
      }
    else
      {
        "title": "Follow on #{title}",
        "aria-label": "Follow on #{title}"
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

  # Builds a nav/footer link for a site shortcut. A "Feed" item copies its link instead of
  # navigating.
  # @param item [Object] A menu item with title, destination, and open_in_new_tab.
  # @return [String] An anchor element.
  def shortcut_link(item)
    if item.title.downcase == 'feed'
      link_to item.title, item.destination, **FEED_CLIPBOARD_ATTRS
    elsif item.open_in_new_tab
      link_to item.title, item.destination, rel: "noopener", target: "_blank"
    else
      link_to item.title, item.destination
    end
  end

  # Builds the footer copyright line. The end year is wrapped for the current-year Stimulus
  # controller to refresh client-side, so it stays correct without a rebuild.
  # @return [String] HTML.
  def footer_text
    years = "#{copyright_start_year}–<span data-controller=\"current-year\">#{Time.current.year}</span>"
    markdown_to_html("© #{years} #{data.site.copyright}")
  end

  # First-party proxy paths for Plausible analytics. Must match the constants in
  # src/plausible.ts, which does the proxying.
  PLAUSIBLE_SCRIPT_PATH = '/pa/script.js'
  PLAUSIBLE_EVENT_PATH = '/pa/event'

  # @return [String] The first-party path the Plausible script is proxied from.
  def plausible_script_path
    PLAUSIBLE_SCRIPT_PATH
  end

  # @return [String] The first-party path Plausible events are posted to.
  def plausible_event_path
    PLAUSIBLE_EVENT_PATH
  end

  # Whether analytics is configured. Gates the analytics script tag; the Worker checks its own
  # copy of the variable before serving /pa/*.
  # @return [Boolean] True when PLAUSIBLE_SCRIPT_URL is set.
  def plausible_installed?
    ENV['PLAUSIBLE_SCRIPT_URL'].present?
  end

  # Builds a stable URL-based @id for a sitewide schema.org entity, so other nodes can reference
  # it rather than duplicating it.
  # @param fragment [String] The fragment naming the entity, e.g. "organization".
  # @param path [String] The page the entity is anchored to.
  # @return [String] An absolute URL with a fragment.
  def schema_entity_id(fragment, path: '/')
    "#{full_url(path)}##{fragment}"
  end

  # Builds the JSON-LD CollectionPage schema for a taxonomy archive page, with the listed
  # entries as its mainEntity ItemList.
  # @param content [Object] The proxied tag-page object.
  # @see https://schema.org/CollectionPage
  # @return [String] JSON-LD.
  def collection_page_schema(content)
    schema = {
      "@context": "https://schema.org",
      "@type": "CollectionPage",
      "name": sanitize(content.title),
      "description": sanitize(content_summary(content)),
      "url": canonical_url,
      "about": {
        "@type": "Thing",
        "name": sanitize(content.title)
      },
      "isPartOf": { "@id": schema_entity_id('website') }
    }
    items = Array(content.items)
    if items.present?
      schema["mainEntity"] = {
        "@type": "ItemList",
        "numberOfItems": items.size,
        "itemListElement": items.each_with_index.map do |item, i|
          { "@type": "ListItem", "position": i + 1, "url": full_url(item.path), "name": sanitize(item.title) }
        end
      }
    end
    schema.to_json
  end

  # Builds a JSON-LD ImageObject node.
  # @return [Hash]
  def image_object(url, width, height)
    { "@type": "ImageObject", "url": url, "width": width, "height": height }
  end

  # Builds a JSON-LD BreadcrumbList of Home › Blog › the given crumbs.
  # @param crumbs [Array<Array(String, String)>] [name, url] pairs appended after Home › Blog.
  # @see https://schema.org/BreadcrumbList
  # @return [String] JSON-LD.
  def breadcrumb_list_schema(crumbs)
    items = [['Home', full_url('/')], ['Blog', full_url('/blog')], *crumbs].map.with_index(1) do |(name, url), position|
      { "@type": "ListItem", "position": position, "name": name, "item": url }
    end
    { "@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": items }.to_json
  end

  # Builds the JSON-LD BreadcrumbList for a taxonomy archive page: Home › Blog › the concept's
  # ancestor chain, ending at the concept itself.
  # @param content [Object] The proxied tag-page object, carrying `tag_id`.
  # @return [String, nil] JSON-LD, or nil when the page has no concept.
  def tag_breadcrumb_schema(content)
    return unless content.tag_id
    chain = concept_chain(content.tag_id)
    return if chain.empty?

    breadcrumb_list_schema(chain.map { |node| [sanitize(node[:name]), full_url(node[:path])] })
  end

  # Builds the JSON-LD Blog schema for the blog index, listing this page's entries as blogPost
  # references.
  # @param content [Object] The proxied blog-index page object.
  # @see https://schema.org/Blog
  # @return [String] JSON-LD.
  def blog_schema(content)
    posts = Array(content.items).map do |item|
      {
        "@type": "BlogPosting",
        "headline": sanitize(item.title),
        "url": full_url(item.path),
        "datePublished": published_datetime(item).iso8601,
        "author": { "@id": schema_entity_id('person', path: '/about') }
      }
    end
    {
      "@context": "https://schema.org",
      "@type": "Blog",
      "name": sanitize(content.title),
      "description": sanitize(data.site.meta_description),
      "url": canonical_url,
      "isPartOf": { "@id": schema_entity_id('website') },
      "publisher": { "@id": schema_entity_id('organization') },
      "blogPost": posts
    }.to_json
  end

  # Builds redirects from each concept's synonyms to its canonical archive page. Skips a synonym
  # whose slug is blank, collides with a real tag page, or duplicates another redirect.
  # @return [Array<Hash>] Entries of { from:, to:, status: }.
  def taxonomy_synonym_redirects
    page_paths = data.tags.map { |t| t.tag.path }.to_set
    taken = data.redirects.map(&:from).to_set
    data.tags.flat_map do |entry|
      tag = entry.tag
      Array(tag.synonyms).filter_map do |synonym|
        slug = synonym.to_s.parameterize
        next if slug.blank?
        from = "/tagged/#{slug}"
        next if page_paths.include?("#{from}/") || taken.include?(from)
        taken << from
        { from: from, to: tag.path, status: 301 }
      end
    end
  end

  # The author's areas of expertise for schema.org `knowsAbout`: the top-level concepts of the
  # `sports` scheme. Content-type and meta topics are excluded — they aren't subjects of
  # expertise.
  # @return [Array<String>] Sorted discipline names.
  def author_knows_about
    Array(data.tags)
      .map(&:tag)
      .select { |t| t.scheme == 'sports' && t.parent_id.blank? }
      .map(&:name)
      .uniq
      .sort
  end

  # The author's social-profile URLs for schema.org `sameAs`. The feed is excluded — it isn't a
  # social profile.
  # @return [Array<String>] Profile URLs.
  def author_same_as
    return [] if data.site.socials_collection.items.blank?
    data.site.socials_collection.items
      .reject { |s| s.title.downcase == 'feed' }
      .map { |s| s.destination }
  end

  # Builds the JSON-LD @graph of the site's sitewide entities — Organization, WebSite, and the
  # author Person — connected by @id. Per-article schema references these rather than repeating
  # them.
  # @see https://developers.google.com/search/docs/appearance/structured-data/organization
  # @return [String] JSON-LD.
  def site_schema_graph
    same_as = author_same_as

    organization = {
      "@type": "Organization",
      "@id": schema_entity_id('organization'),
      "name": sanitize(data.site.title),
      "url": full_url('/')
    }
    organization["logo"] = site_icon_url(w: 180) if data.site.logo.present?
    organization["sameAs"] = same_as if same_as.present?

    website = {
      "@type": "WebSite",
      "@id": schema_entity_id('website'),
      "name": sanitize(data.site.title),
      "url": full_url('/'),
      "inLanguage": "en-US",
      "publisher": { "@id": schema_entity_id('organization') }
    }

    person = {
      "@type": "Person",
      "@id": schema_entity_id('person', path: '/about'),
      "name": data.site.author.name,
      "url": full_url('/about')
    }
    person["sameAs"] = same_as if same_as.present?
    knows_about = author_knows_about
    person["knowsAbout"] = knows_about if knows_about.present?
    if data.site.author.profile_picture&.url.present?
      picture = data.site.author.profile_picture
      person["image"] = image_object(cdn_image_url(picture.url, { w: 500, h: 500, fit: 'cover' }), 500, 500)
      person["image"][:caption] = sanitize(picture.description) if picture.description.present?
    end

    {
      "@context": "https://schema.org",
      "@graph": [organization, website, person]
    }.to_json
  end

  # Builds the JSON-LD ProfilePage schema marking the about page as the canonical page about the
  # author Person.
  # @see https://developers.google.com/search/docs/appearance/structured-data/profile-page
  # @return [String] JSON-LD.
  def profile_page_schema
    {
      "@context": "https://schema.org",
      "@type": "ProfilePage",
      "mainEntity": { "@id": schema_entity_id('person', path: '/about') }
    }.to_json
  end
end
