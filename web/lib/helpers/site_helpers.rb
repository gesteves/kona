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
  #
  # ⚠️ Middleman's `content_tag` does not escape its content, and `page_title` decodes each
  # entity. Thus the escape is here.
  def title_tag(content)
    content_tag :title do
      ERB::Util.html_escape(page_title(content, include_site_name: true))
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

  # The longest description that this method returns. A search engine shows approximately 160
  # characters and each unfurl cuts at its own length, thus a longer string only removes the control
  # of what a reader sees.
  SUMMARY_LENGTH = 200

  # @param content [Object] A content object.
  # @return [String] The summary, the intro, or the meta description of the site — the first one
  #   that exists, cut to SUMMARY_LENGTH.
  #
  # ⚠️ The cut is at the END, and it covers each branch. A Short has no summary field and its intro
  # is the full post, thus that branch gave a description of some thousands of characters. An
  # authored `summary` has no limit either. One cut here is one rule.
  # ⚠️ Four places read this: the meta description, og:description, BlogPosting.description, and the
  # Atom <summary>. The Atom <content> still holds the full post, thus a shorter summary there is
  # correct.
  def content_summary(content)
    summary = if content.summary.present?
      content.summary
    elsif content.entry_type == "Short"
      content.intro
    elsif content.intro.present?
      content.intro
    else
      data.site.meta_description
    end
    # ⚠️ The omission is the one character, and not "...": smartypants would make the three dots
    # into `&hellip;`, and the Atom summary, which is plain text, would then show that entity.
    sanitize(summary)&.truncate(SUMMARY_LENGTH, omission: "…")
  end

  # @return [DateTime] The latest publish time of the pages, the articles, and the site entry.
  def site_updated_at
    [
      indexable_pages.map { |p| DateTime.parse(p.sys.published_at) },
      indexable_articles.map { |a| DateTime.parse(a.sys.published_at) },
      DateTime.parse(data.site.sys.published_at)
    ].flatten.max
  end

  # The value of <lastmod> in the sitemap.
  # ⚠️ Keep the time. IndexNow compares this string, thus a date alone makes a second edit of the
  # same day invisible, and no URL goes to the engines.
  # @param value [String, DateTime] A timestamp, or the DateTime that site_updated_at gives.
  # @return [String] A W3C datetime, for example 2026-09-05T18:57:14+00:00.
  def sitemap_lastmod(value)
    (value.is_a?(String) ? DateTime.parse(value) : value).iso8601
  end

  # The robots.txt rules that block the AI scrapers, for source/robots.txt.erb. `rake import` gets
  # them from Known Agents and writes data/known_agents.json.
  # ⚠️ A failed import writes no file, and `rake clobber` removes the file of the last run. Thus
  # the guard here is necessary: a bare data.known_agents is nil, and it stops the build.
  # @return [String] The rules and a blank line after them, or "" when the file is absent.
  def known_agent_rules
    rules = data.respond_to?(:known_agents) ? data.known_agents&.robots_txt.to_s.strip : ""
    rules.present? ? "#{rules}\n\n" : ""
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
  # page. ⚠️ An article page advertises the main feed only. Feed autodiscovery has no order of
  # preference, thus a tag feed there can send a reader to a narrow feed.
  # @return [Array<Hash>] Items of { href:, title: }.
  def alternate_feed_links
    links = [ { href: full_url("/feed.xml"), title: sanitize(data.site.meta_title) } ]
    pc = page_content
    tags = if pc.nil?
      []
    elsif pc.template == "/tag.html" && pc.tag_id
      node = taxonomy_index[pc.tag_id] # the tag itself
      node ? [ node ] : []
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
  # navigation. The link to the page that renders now gets aria-current="page".
  # @param item [Object] A menu item with title, destination, and open_in_new_tab.
  # @return [String] An anchor element.
  def shortcut_link(item)
    if item.title.downcase == "feed"
      link_to item.title, item.destination, **FEED_CLIPBOARD_ATTRS
    elsif item.open_in_new_tab
      link_to item.title, item.destination, rel: "noopener", target: "_blank"
    elsif current_shortcut?(item.destination)
      link_to item.title, item.destination, "aria-current": "page"
    else
      link_to item.title, item.destination
    end
  end

  # Tells if a menu destination is the page that renders now.
  #
  # ⚠️ A destination comes from Contentful, thus it can have a slash at the end or no slash. The
  # comparison adds the slash to both, because `activate :directory_indexes` puts each page at
  # /<slug>/. An absolute URL and a protocol-relative URL are never the current page.
  # @param destination [String] The destination of the menu item.
  # @return [Boolean]
  def current_shortcut?(destination)
    return false if destination.blank?
    return false if destination.match?(%r{\A([a-z][a-z0-9+.\-]*:|//)}i)

    here = (current_page.url if defined?(current_page))
    return false if here.blank?

    normalize_menu_path(here) == normalize_menu_path(destination)
  end

  # @param path [String] A path, with or without the slash at the end.
  # @return [String] The path with one slash at the end, and with no query and no fragment.
  def normalize_menu_path(path)
    path.to_s.split(/[?#]/).first.to_s.chomp("/") + "/"
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

  # The name of the Plausible goal for a click on a link into an article. ⚠️ The goal in the
  # dashboard must have this exact text. Plausible drops an event that no goal matches, and it does
  # not fill in the data from before. The api has a copy in helpers/plausible_helper.rb.
  ARTICLE_CLICK_EVENT = "Article Click"

  # Makes the Plausible tagged-event classes for a link into an article. The tracking script reads
  # the class names of the link and sends one event, with the section and the destination URL.
  # ⚠️ A section name is the heading of the section, word for word. It can have a space, because
  # the script changes each "+" back into a space, but it must have no "=" and no "--": the script
  # parses the class name with /plausible-event-(.+)(=|--)(.+)/.
  # ⚠️ It gives nil for a blank section. The name class on its own sends an event with no section,
  # and nothing shows that error.
  # @param section [String] The analytics name of the section that holds the link.
  # @return [String, nil] The class names, or nil.
  def article_click_classes(section)
    return if section.blank?

    "plausible-event-name=#{plausible_class_value(ARTICLE_CLICK_EVENT)} " \
      "plausible-event-section=#{plausible_class_value(section)}"
  end

  # @param value [String] The text of an event name or of a property value.
  # @return [String] That text as one class name. A space becomes a "+", which the script reads
  #   back as a space. A value with a space and no encoding would become more than one class name.
  def plausible_class_value(value)
    value.tr(" ", "+")
  end
end
