require "sanitize"

module SiteHelpers
  # The public Cloudflare Turnstile sitekey for the contact form. It is blank if no one sets it.
  # The site then does not render the widget and the api does not do the check.
  # @return [String, nil]
  def turnstile_site_key
    ENV["TURNSTILE_SITE_KEY"]
  end

  # The IANA timezone for the dates of the site. It is the location of the owner. Thus "published
  # today", the clock or calendar icon, and the "New" badge change at the same moment for each
  # reader, and not in the zone of each reader.
  # @return [String, nil] Blank if no one sets it. The publish-date controller then uses the
  #   browser timezone of the reader.
  def site_time_zone
    ENV["TIME_ZONE"].presence
  end

  # Makes an Atom tag URI from a URL and a date.
  # @param url [String] The URL to change.
  # @param date [Date, Time] The date for the tag.
  # @return [String] The Atom tag URI.
  def atom_tag(url, date)
    tag = url.gsub(/^http(s)?:\/\//, "").gsub("#", "/").split("/")
    tag[0] = "tag:#{tag[0]},#{date.strftime('%Y-%m-%d')}:"
    tag.join("/")
  end

  # Makes the page title.
  # @param content [Hash, String] A content object (this uses its :title) or a title string.
  # @param include_site_name [Boolean] True to add the title of the site at the end.
  # @param separator [String] The separator between the title parts.
  # @return [String] The title, after the app removes unsafe markup.
  def page_title(content, include_site_name: false, separator: " · ")
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
  # @return [String] A <title> tag that contains the page title and the site name.
  def title_tag(content)
    content_tag :title do
      page_title(content, include_site_name: true)
    end
  end

  # Renders the placeholder partial of a runtime widget. The partial points at the endpoint that
  # the live-update controller gets on connect.
  # Do not use <link rel="preload" as="fetch"> with these. The app serves widget fragments with
  # `max-age=0` and no validator. Thus a preloaded copy is already old when it arrives, and the
  # controller makes a second full request instead of a re-use of that copy.
  # @param name [String] The base name of the partial in partials/placeholders/.
  # @param url [String] The same-origin widget endpoint. It goes to the partial as `url`.
  # @return [String] The rendered placeholder.
  def render_widget(name, url)
    partial "partials/placeholders/#{name}", locals: { url: url }
  end

  # The proxied `content` object for the current page. It comes from the page metadata, because
  # a helper cannot read the template locals.
  # @return [Object, nil]
  def page_content
    locals = current_page.metadata[:locals]
    locals && locals[:content]
  end

  # The object that supplies the <title> and og:title of the page: the proxied content object,
  # or the frontmatter title.
  # @return [Object, String, nil]
  def meta_title_source
    page_content || current_page.data.title.presence
  end

  # The meta and og description of the page: the content summary, or the frontmatter summary.
  # @return [String, nil]
  def meta_description
    return content_summary(page_content) if page_content
    current_page.data.summary.presence
  end

  # The attributes for the outer tag of a live-update element. Put them in its opening tag. The
  # api fragment that replaces the element has all of these but the placeholder flag. Refer to
  # the web↔api contract in the root CLAUDE.md.
  # @param url [String] The same-origin widget endpoint.
  # @param placeholder [Boolean] True if this element is an empty skeleton with no real content.
  # @return [String] The HTML attributes.
  def live_update_attrs(url, placeholder: true)
    # The app always makes url as a same-origin path. It is never user input, thus it needs no
    # escape. aria-busy shows that the skeleton still loads. The api fragment that replaces it
    # does not have aria-busy, as it does not have the placeholder flag. Thus a screen reader
    # reads the change as "finished", and not as one nameless area in place of another.
    #
    # ⚠️ Use `placeholder: false` for an element that the build renders with REAL content. The
    # flag means "I am an empty skeleton". It makes the controller remove the element when a
    # fetch fails, and on real content that deletes the content. Such an element still fetches on
    # connect, because a URL with no fetch counts as old. Thus the removal of the flag costs no
    # freshness. An empty response still removes the element, which is the "no data" answer from
    # the api.
    attrs = %(data-controller="live-update" data-live-update-url-value="#{url}")
    attrs += %( data-live-update-placeholder-value="true" aria-busy="true") if placeholder
    attrs += %( data-action="visibilitychange@document->live-update#handleVisibilityChange")
    attrs.html_safe
  end

  # @param content [Object] A content object.
  # @return [String] The summary, the intro, or the meta description of the site — the first one
  #   that exists.
  def content_summary(content)
    summary = if content.summary.present?
      content.summary
    elsif content.entry_type == "Short"
      content.intro
    elsif content.intro.present?
      content.intro&.truncate(200)
    else
      data.site.meta_description
    end
    sanitize(summary)
  end

  # @return [DateTime] The latest publish time of the pages, the articles, and the site entry.
  def site_updated_at
    [
      indexable_pages.map { |p| DateTime.parse(p.sys.published_at) },
      indexable_articles.map { |a| DateTime.parse(a.sys.published_at) },
      DateTime.parse(data.site.sys.published_at)
    ].flatten.max
  end

  # The year of the first non-draft article. The app keeps the value, because it renders in the
  # footer of each page and each calculation parses the publish date of each article.
  # @return [String] A four-digit year.
  def copyright_start_year
    memoize_by_collection(:copyright_start_year, data.articles) do
      earliest = published_articles.map { |a| published_datetime(a) }.min
      earliest.nil? ? Time.current.year.to_s : earliest.strftime("%Y")
    end
  end

  # @return [String] The range of copyright years, for example "2006–2024".
  def copyright_years
    "#{copyright_start_year}–#{Time.current.year}"
  end

  # The Atom feeds for the <head>: the main site feed, and also the feed of the tag on an archive
  # page, or the feed of each tag of the article on a post.
  # @return [Array<Hash>] Items of { href:, title: }.
  def alternate_feed_links
    links = [ { href: full_url("/feed.xml"), title: sanitize(data.site.meta_title) } ]
    pc = page_content
    tags = if pc.nil?
      []
    elsif pc.template == "/tag.html" && pc.tag_id
      node = taxonomy_index[pc.tag_id] # the tag itself
      node ? [ node ] : []
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

  # @return [String] The feed title, from the meta title of the site.
  def feed_title
    data.site.meta_title.split(":", 2).first.strip
  end

  # @return [String, nil] The feed subtitle, or nil if the meta title has no second part.
  def feed_subtitle
    subtitle = data.site.meta_title.split(":", 2).last.strip
    return if subtitle == feed_title
    subtitle
  end

  # The attributes that make a feed link copy its URL to the clipboard instead of navigation.
  # MarkupHelpers#copy_feed_links also uses them for feed links in rendered bodies.
  FEED_CLIPBOARD_ATTRS = {
    "data-controller": "clipboard",
    "data-action": "click->clipboard#copy",
    "data-clipboard-success-message-value": "The link to the feed has been copied to your clipboard."
  }.freeze

  # Makes a social media link. A "Feed" link copies its URL instead of navigation.
  # @param title [String] The name of the platform.
  # @param destination [String] The profile URL.
  # @param css_class [String] A CSS class for the link.
  # @param open_in_new_tab [Boolean] True to open the link in a new tab.
  # @return [String] An anchor element that contains an SVG icon.
  def social_media_link(title:, destination:, css_class: nil, open_in_new_tab: true)
    icon = if title.downcase == "feed"
      icon_svg("classic", "solid", "rss")
    else
      icon_svg("classic", "brands", title.downcase)
    end

    icon = icon_svg("classic", "solid", "link") if icon.blank?

    options = if title.downcase == "feed"
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

  # Makes a nav or footer link for a site shortcut. A "Feed" item copies its link instead of
  # navigation.
  # @param item [Object] A menu item with title, destination, and open_in_new_tab.
  # @return [String] An anchor element.
  def shortcut_link(item)
    if item.title.downcase == "feed"
      link_to item.title, item.destination, **FEED_CLIPBOARD_ATTRS
    elsif item.open_in_new_tab
      link_to item.title, item.destination, rel: "noopener", target: "_blank"
    else
      link_to item.title, item.destination
    end
  end

  # Makes the copyright line in the footer. The last year is in an element that the current-year
  # Stimulus controller updates in the browser. Thus it stays correct with no new build.
  # @return [String] HTML.
  def footer_text
    years = "#{copyright_start_year}–<span data-controller=\"current-year\">#{Time.current.year}</span>"
    markdown_to_html("© #{years} #{data.site.copyright}")
  end

  # The first-party proxy paths for Plausible analytics. They must agree with the constants in
  # src/plausible.ts, which does the proxy work.
  PLAUSIBLE_SCRIPT_PATH = "/pa/script.js"
  PLAUSIBLE_EVENT_PATH = "/pa/event"

  # @return [String] The first-party path that supplies the Plausible script.
  def plausible_script_path
    PLAUSIBLE_SCRIPT_PATH
  end

  # @return [String] The first-party path that receives the Plausible events.
  def plausible_event_path
    PLAUSIBLE_EVENT_PATH
  end

  # Tells if the analytics configuration exists. It controls the analytics script tag. The Worker
  # reads its own copy of the variable before it serves /pa/*.
  # @return [Boolean] True if PLAUSIBLE_SCRIPT_URL has a value.
  def plausible_installed?
    ENV["PLAUSIBLE_SCRIPT_URL"].present?
  end

  # Makes a stable URL @id for a sitewide schema.org entity. Thus other nodes can refer to it and
  # do not repeat it.
  # @param fragment [String] The fragment that names the entity, for example "organization".
  # @param path [String] The page that holds the entity.
  # @return [String] An absolute URL with a fragment.
  def schema_entity_id(fragment, path: "/")
    "#{full_url(path)}##{fragment}"
  end

  # Makes the JSON-LD CollectionPage schema for a taxonomy archive page. The entries in the list
  # are its mainEntity ItemList.
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
      "isPartOf": { "@id": schema_entity_id("website") }
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

  # Makes a JSON-LD ImageObject node.
  # @return [Hash]
  def image_object(url, width, height)
    { "@type": "ImageObject", "url": url, "width": width, "height": height }
  end

  # Makes a JSON-LD BreadcrumbList: Home › Blog › the given crumbs.
  # @param crumbs [Array<Array(String, String)>] The [name, url] pairs that go after Home › Blog.
  # @see https://schema.org/BreadcrumbList
  # @return [String] JSON-LD.
  def breadcrumb_list_schema(crumbs)
    items = [ [ "Home", full_url("/") ], [ "Blog", full_url("/blog") ], *crumbs ].map.with_index(1) do |(name, url), position|
      { "@type": "ListItem", "position": position, "name": name, "item": url }
    end
    { "@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": items }.to_json
  end

  # Makes the JSON-LD BreadcrumbList for a taxonomy archive page: Home › Blog › the chain of
  # parents of the concept, and then the concept.
  # @param content [Object] The proxied tag-page object, which holds `tag_id`.
  # @return [String, nil] The JSON-LD, or nil if the page has no concept.
  def tag_breadcrumb_schema(content)
    return unless content.tag_id
    chain = concept_chain(content.tag_id)
    return if chain.empty?

    breadcrumb_list_schema(chain.map { |node| [ sanitize(node[:name]), full_url(node[:path]) ] })
  end

  # Makes the JSON-LD Blog schema for the blog index. The entries of this page are blogPost
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
        "author": { "@id": schema_entity_id("person", path: "/about") }
      }
    end
    {
      "@context": "https://schema.org",
      "@type": "Blog",
      "name": sanitize(content.title),
      "description": sanitize(data.site.meta_description),
      "url": canonical_url,
      "isPartOf": { "@id": schema_entity_id("website") },
      "publisher": { "@id": schema_entity_id("organization") },
      "blogPost": posts
    }.to_json
  end

  # Makes a redirect from each synonym of a concept to its canonical archive page. It ignores a
  # synonym with a blank slug, a synonym that is the same as a real tag page, and a synonym that
  # is the same as another redirect.
  # @return [Array<Hash>] Items of { from:, to:, status: }.
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

  # @param from [String] A redirect source.
  # @return [Boolean] True if Cloudflare counts the rule as "dynamic", that is, the source has
  #   a splat or a :placeholder.
  def dynamic_redirect_source?(from)
    from.include?("*") || from.match?(/:[A-Za-z]/)
  end

  # All the redirect rules, in the order that source/redirects.erb must write them.
  #
  # ⚠️ THE ORDER OF THE RULES IS IMPORTANT. The Cloudflare parser permits 2,000 "static" rules but
  # only 100 "dynamic" rules. It also *latches*: at the first dynamic rule, each subsequent rule
  # counts as dynamic, exact matches included. Write the static rules first, or the deploy fails
  # with only `code: 100324` when the file becomes longer than approximately 100 lines. The static
  # rules first is also the correct match order. This code is outside the template, thus you can
  # test it. Refer to the root and web CLAUDE.md.
  # @return [Array(Array<Hash>, Array<Hash>)] The static rules, then the dynamic rules.
  def partitioned_redirects
    rules =
      [
        { from: "/.well-known/host-meta*", to: "https://fed.brid.gy/.well-known/host-meta:splat", status: 302 },
        { from: "/.well-known/webfinger*", to: "https://fed.brid.gy/.well-known/webfinger", status: 302 }
      ] +
      taxonomy_synonym_redirects.map { |r| { from: r[:from], to: r[:to], status: r[:status] } } +
      data.redirects.map { |r| { from: r.from, to: r.to, status: r.status } }

    # ⚠️ The Cloudflare _redirects file accepts only RELATIVE sources. A `from` with an absolute
    # URL causes a deploy failure (code 100324). The redirects come from Contentful, thus this
    # check is between an incorrect rule and a broken deploy. Put a cross-domain redirect in a
    # zone Bulk Redirect.
    rules.reject! { |r| r[:from].match?(%r{\Ahttps?://}) }
    # ⚠️ The same is true for a 200-status proxy rewrite to an absolute URL. Nothing writes one
    # today, because the Worker does the /pa/* proxy, but the same path could write one.
    rules.reject! { |r| r[:status].to_i == 200 && r[:to].to_s.match?(%r{\Ahttps?://}) }

    rules.partition { |r| !dynamic_redirect_source?(r[:from]) }
  end

  # The subjects that the author knows, for schema.org `knowsAbout`: the top-level concepts of
  # the `sports` scheme. This does not include the content-type topics and the meta topics,
  # because they are not subjects of knowledge.
  # @return [Array<String>] The discipline names, in order.
  def author_knows_about
    Array(data.tags)
      .map(&:tag)
      .select { |t| t.scheme == "sports" && t.parent_id.blank? }
      .map(&:name)
      .uniq
      .sort
  end

  # The social-profile URLs of the author, for schema.org `sameAs`. This does not include the
  # feed, because a feed is not a social profile.
  # @return [Array<String>] Profile URLs.
  def author_same_as
    return [] if data.site.socials_collection.items.blank?
    data.site.socials_collection.items
      .reject { |s| s.title.downcase == "feed" }
      .map { |s| s.destination }
  end

  # Makes the JSON-LD @graph of the sitewide entities: Organization, WebSite, and the author
  # Person. @id connects them. The schema of each article refers to them and does not repeat
  # them.
  # @see https://developers.google.com/search/docs/appearance/structured-data/organization
  # @return [String] JSON-LD.
  def site_schema_graph
    same_as = author_same_as

    organization = {
      "@type": "Organization",
      "@id": schema_entity_id("organization"),
      "name": sanitize(data.site.title),
      "url": full_url("/")
    }
    organization["logo"] = site_icon_url(w: 180) if data.site.logo.present?
    organization["sameAs"] = same_as if same_as.present?

    website = {
      "@type": "WebSite",
      "@id": schema_entity_id("website"),
      "name": sanitize(data.site.title),
      "url": full_url("/"),
      "inLanguage": "en-US",
      "publisher": { "@id": schema_entity_id("organization") }
    }

    person = {
      "@type": "Person",
      "@id": schema_entity_id("person", path: "/about"),
      "name": data.site.author.name,
      "url": full_url("/about")
    }
    person["sameAs"] = same_as if same_as.present?
    knows_about = author_knows_about
    person["knowsAbout"] = knows_about if knows_about.present?
    if data.site.author.profile_picture&.url.present?
      picture = data.site.author.profile_picture
      person["image"] = image_object(cdn_image_url(picture.url, { w: 500, h: 500, fit: "cover" }), 500, 500)
      person["image"][:caption] = sanitize(picture.description) if picture.description.present?
    end

    {
      "@context": "https://schema.org",
      "@graph": [ organization, website, person ]
    }.to_json
  end

  # Makes the JSON-LD ProfilePage schema. It marks the about page as the canonical page about
  # the author Person.
  # @see https://developers.google.com/search/docs/appearance/structured-data/profile-page
  # @return [String] JSON-LD.
  def profile_page_schema
    {
      "@context": "https://schema.org",
      "@type": "ProfilePage",
      "mainEntity": { "@id": schema_entity_id("person", path: "/about") }
    }.to_json
  end
end
