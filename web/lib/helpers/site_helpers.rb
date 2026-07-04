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

  # Registers a runtime-widget fragment to be <link rel="preload" as="fetch">ed in the <head>
  # (rendered high up by the `yield_content :preloads` slot). The live-update controller only fetch()es
  # these after the deferred JS bundle boots, so the browser discovers them late; preloading
  # starts the request during HTML parse, in parallel with the bundle. crossorigin="anonymous"
  # makes the preload's mode ("cors") and credentials mode ("same-origin") match the
  # controller's bare same-origin fetch(), so the browser reuses the preloaded response instead
  # of discarding it as unused (the "preload was not used within a few seconds" console warning)
  # and issuing a second request. Call it alongside each widget placeholder, under the same
  # condition, so a fragment is only preloaded on pages that actually fetch it.
  # @param url [String] The same-origin widget endpoint the live-update controller will fetch.
  # @return [void]
  def preload_widget(url)
    content_for :preloads do
      # url is always an app-generated same-origin path (widget endpoint, ids are alphanumeric),
      # never user input, so it needs no escaping here.
      %(<link rel="preload" as="fetch" href="#{url}" crossorigin="anonymous">).html_safe
    end
  end

  # The proxied `content` object for the current page, if any. Templates receive it as a
  # local (set via `proxy … locals:` in config.rb), but helper methods can't see template
  # locals — they read it from the page metadata instead.
  # @return [Object, nil]
  def page_content
    locals = current_page.metadata[:locals]
    locals && locals[:content]
  end

  # The object driving the current page's <title> and og:title: the proxied `content` object
  # when the page has one, else the page frontmatter's title string (nil when neither exists —
  # the caller emits nothing). Collapses the content-vs-frontmatter fallback that was
  # open-coded in partials/_meta and partials/_open_graph_and_social.
  # @return [Object, String, nil]
  def meta_title_source
    page_content || current_page.data.title.presence
  end

  # The current page's meta/og description: the content summary when the page has a `content`
  # object (never blank — content_summary falls back to the site meta description), else the
  # page frontmatter's summary (nil when neither exists).
  # @return [String, nil]
  def meta_description
    return content_summary(page_content) if page_content
    current_page.data.summary.presence
  end

  # The attribute cluster every live-update placeholder's outer element carries: wires the
  # element to the live-update Stimulus controller, pointing at the widget endpoint it fetches
  # on connect and refetches on visibilitychange (see root CLAUDE.md for the web↔api contract).
  # Interpolate inside the placeholder's outer tag.
  # @param url [String] The same-origin widget endpoint.
  # @return [String] HTML attributes.
  def live_update_attrs(url)
    # url is always an app-generated same-origin path (widget endpoint, ids are alphanumeric),
    # never user input, so it needs no escaping here.
    %(data-controller="live-update" data-live-update-url-value="#{url}" data-live-update-fetch-on-connect-value="true" data-action="visibilitychange@document->live-update#handleVisibilityChange").html_safe
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
      indexable_pages.map { |p| DateTime.parse(p.sys.published_at) },
      indexable_articles.map { |a| DateTime.parse(a.sys.published_at) },
      DateTime.parse(data.site.sys.published_at)
    ].flatten.max
  end

  # The year the earliest non-draft article was published — the start of the copyright range.
  # Computed once per build (memoize_by_collection): it renders in the footer of every page,
  # and each computation parses every article's publish date.
  # @return [String] e.g. "2006".
  def copyright_start_year
    memoize_by_collection(:copyright_start_year, data.articles) do
      published_articles.map { |a| published_datetime(a) }.min.strftime('%Y')
    end
  end

  # Returns a range of years, from the year the earliest article was published to the current year.
  # @return [String] A range of years, like 2006-2024.
  def copyright_years
    "#{copyright_start_year}–#{Time.current.year}"
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
        "aria-label": "Subscribe to the feed",
        "data-controller": "clipboard",
        "data-action": "click->clipboard#copy",
        "data-clipboard-success-message-value": "The link to the feed has been copied to your clipboard."
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

  # A nav/footer menu link for a site shortcut item: the feed item copies its link to the
  # clipboard instead of navigating, open_in_new_tab items get target=_blank + noopener,
  # and everything else is a plain link.
  # @param item [Object] A menu item with title, destination, and open_in_new_tab.
  # @return [String] An anchor element.
  def shortcut_link(item)
    if item.title.downcase == 'feed'
      link_to item.title, item.destination, "data-controller": "clipboard", "data-clipboard-success-message-value": "The link to the feed has been copied to your clipboard.", "data-action": "click->clipboard#copy"
    elsif item.open_in_new_tab
      link_to item.title, item.destination, rel: "noopener", target: "_blank"
    else
      link_to item.title, item.destination
    end
  end

  # Formats the text at the very bottom of the footer. The end year is wrapped in a span that the
  # current-year Stimulus controller refreshes client-side, so the copyright stays correct without a
  # rebuild (the build-time year is the no-JS fallback). Feeds keep the plain `copyright_years`.
  # @return [String] A string of HTML.
  def footer_text
    years = "#{copyright_start_year}–<span data-controller=\"current-year\">#{Time.current.year}</span>"
    markdown_to_html("© #{years} #{data.site.copyright}")
  end

  # The normalized path → title map consumed by the OG image function (netlify/functions/og.mts)
  # via /og/data.json.
  # @return [Hash] Normalized page path (trailing-slash form) → rendered page title.
  def og_page_titles
    titles = {}
    [data.articles, data.pages].each do |collection|
      (collection || []).reject(&:draft).each do |entry|
        key = og_normalized_path(entry.path)
        titles[key] = page_title(entry) if key && entry.title
      end
    end
    titles
  end

  # Normalizes a built page path ("/foo/index.html") to its public trailing-slash form ("/foo/").
  # @return [String, nil]
  def og_normalized_path(path)
    return if path.nil?
    path = path.sub(/\/index\.html\z/, '/')
    path.empty? ? '/' : path
  end

  # First-party proxy paths for Plausible analytics. Both the inline init
  # snippet (partials/_analytics.html.erb) and the Netlify `_redirects` rewrites
  # (source/redirects.erb) read these, so the browser-facing path and the proxy
  # target stay in sync from a single source.
  # @see https://plausible.io/docs/proxy/guides/netlify
  PLAUSIBLE_SCRIPT_PATH = '/plsbl/script.js'
  PLAUSIBLE_EVENT_PATH = '/plsbl/event'
  PLAUSIBLE_EVENT_UPSTREAM = 'https://plausible.io/api/event'

  # The first-party path the Plausible script is proxied from.
  # @return [String]
  def plausible_script_path
    PLAUSIBLE_SCRIPT_PATH
  end

  # The first-party path Plausible events are sent to (the `endpoint` passed to
  # `plausible.init`). Proxied to the upstream Plausible event API.
  # @return [String]
  def plausible_event_path
    PLAUSIBLE_EVENT_PATH
  end

  # The Plausible proxy rewrite rules to emit into the `_redirects` file. Only
  # built when an upstream script URL is configured (see plausible_installed?),
  # so a missing `PLAUSIBLE_SCRIPT_URL` never emits a malformed rewrite line.
  # @return [Array<Hash>] Each rule with :from, :to, and :status keys.
  def plausible_proxy_redirects
    return [] unless plausible_installed?
    [
      { from: PLAUSIBLE_SCRIPT_PATH, to: ENV['PLAUSIBLE_SCRIPT_URL'], status: 200 },
      { from: PLAUSIBLE_EVENT_PATH, to: PLAUSIBLE_EVENT_UPSTREAM, status: 200 }
    ]
  end

  # Checks if Plausible analytics is installed, i.e. the upstream script URL is
  # configured so the first-party proxy can be built. Gates both the analytics
  # script tag (partials/_analytics.html.erb) and the proxy rewrites.
  # @return [Boolean] True when `PLAUSIBLE_SCRIPT_URL` is set.
  def plausible_installed?
    ENV['PLAUSIBLE_SCRIPT_URL'].present?
  end

  # Builds a stable, URL-based @id for a sitewide schema.org entity. Anchoring the @id to a
  # real URL + fragment makes the node a resolvable entity that other nodes (and the per-article
  # BlogPosting schema) can reference by @id instead of duplicating it.
  # @param fragment [String] The fragment naming the entity, e.g. "organization".
  # @param path [String] The page the entity is anchored to. Defaults to the home page.
  # @return [String] An absolute URL with a fragment, e.g. "https://example.com/#organization".
  def schema_entity_id(fragment, path: '/')
    "#{full_url(path)}##{fragment}"
  end

  # Generates a JSON-LD CollectionPage schema for a taxonomy archive page (`/tagged/*`),
  # declaring the page as a collection about its topic, with the concept's description as the
  # page description. References the sitewide WebSite node by @id rather than duplicating it.
  # @param content [Object] The proxied tag-page object (title = concept name; summary/description).
  # @see https://schema.org/CollectionPage
  # @return [String] A JSON-LD formatted string.
  def collection_page_schema(content)
    {
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
    }.to_json
  end

  # The author's social-profile URLs for schema.org `sameAs` (the feed is excluded — it isn't a
  # social profile). Shared by the Organization and Person nodes in the entity graph.
  # @return [Array<String>] Social profile URLs, or an empty array when none are configured.
  def author_same_as
    return [] if data.site.socials_collection.items.blank?
    data.site.socials_collection.items
      .reject { |s| s.title.downcase == 'feed' }
      .map { |s| s.destination }
  end

  # Generates a JSON-LD @graph of the site's sitewide entities — the Organization (publisher),
  # the WebSite, and the author Person — connected by @id so consumers can resolve "who runs this
  # site / who wrote this / what site is this". Per-article BlogPosting schema references these
  # nodes by @id rather than duplicating them. Rendered sitewide.
  # @see https://developers.google.com/search/docs/appearance/structured-data/organization
  # @return [String] A JSON-LD formatted string.
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
    if data.site.author.profile_picture&.url.present?
      picture = data.site.author.profile_picture
      person["image"] = {
        "@type": "ImageObject",
        "url": cdn_image_url(picture.url, { w: 500, h: 500, fit: 'cover' }),
        "width": 500,
        "height": 500
      }
      person["image"]["caption"] = sanitize(picture.description) if picture.description.present?
    end

    {
      "@context": "https://schema.org",
      "@graph": [organization, website, person]
    }.to_json
  end

  # Generates a JSON-LD ProfilePage schema for the about page, marking it as the canonical page
  # about the author Person (referenced by @id from the sitewide entity graph).
  # @see https://developers.google.com/search/docs/appearance/structured-data/profile-page
  # @return [String] A JSON-LD formatted string.
  def profile_page_schema
    {
      "@context": "https://schema.org",
      "@type": "ProfilePage",
      "mainEntity": { "@id": schema_entity_id('person', path: '/about') }
    }.to_json
  end
end
