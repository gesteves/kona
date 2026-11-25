# The JSON-LD of the site: the sitewide @graph, the blog and the archive pages, the breadcrumbs,
# the author, and one article.
module SchemaHelpers
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
  #
  # ⚠️ The Blog crumb needs the slash at the end. `activate :directory_indexes` puts that page at
  # /blog/, and `html_handling: "auto-trailing-slash"` in wrangler.jsonc answers /blog with a 301.
  # Thus a crumb with no slash points at a redirect, and each other URL on the page is canonical.
  # @param crumbs [Array<Array(String, String)>] The [name, url] pairs that go after Home › Blog.
  # @see https://schema.org/BreadcrumbList
  # @return [String] JSON-LD.
  def breadcrumb_list_schema(crumbs)
    items = [ [ "Home", full_url("/") ], [ "Blog", full_url("/blog/") ], *crumbs ].map.with_index(1) do |(name, url), position|
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
      .reject { |s| feed_link?(s.title) }
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
      "url": full_url("/about/")
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

  # Makes the JSON-LD BlogPosting schema for an article.
  # @see https://developers.google.com/search/docs/appearance/structured-data/article
  # @return [String, nil] The JSON-LD, or nil for a draft.
  def article_schema(content)
    return if content.draft
    schema = {
      "@context": "https://schema.org",
      "@type": "BlogPosting",
      "headline": sanitize(content.title),
      "description": sanitize(content_summary(content)),
      "datePublished": published_datetime(content).iso8601,
      "dateModified": DateTime.parse(content.sys.published_at).iso8601,
      "inLanguage": "en-US",
      "isAccessibleForFree": true,
      "wordCount": article_word_count(content),
      "timeRequired": "PT#{reading_time_minutes(content)}M",
      # @id points to them, thus a consumer finds the one sitewide entity for each.
      "author": { "@id": schema_entity_id("person", path: "/about") },
      "publisher": { "@id": schema_entity_id("organization") },
      "isPartOf": { "@id": schema_entity_id("website") },
      "mainEntityOfPage": {
        "@type": "WebPage",
        "@id": canonical_url
      }
    }
    tags = Array(content.contentful_metadata&.tags)
    if tags.present?
      schema["keywords"] = tags.flat_map { |t| [ t.name, *Array(t.synonyms) ] }.uniq
      # Use the content-type concept first, then a Topics concept, then the first concept.
      section = tags.find { |t| %w[race-reports news reviews].include?(t.id) } ||
                tags.find { |t| t.scheme == "topics" } || tags.first
      schema["articleSection"] = section.name
    end
    if content&.cover_image&.url.present?
      schema["image"] = [ "1000x1000", "1600x900", "1600x1200" ].map do |s|
        w, h = s.split("x").map(&:to_i)
        image_object(cdn_image_url(content.cover_image.url, { w: w, h: h, fit: "cover" }), w, h)
      end
    else
      # There is no cover image. Use the Open Graph card that the app makes, thus the
      # BlogPosting still has an image.
      card_url = open_graph_card_url(current_page.url, content.sys&.published_version)
      schema["image"] = [ image_object(card_url, 1200, 630) ]
    end
    schema.to_json
  end

  # Makes the JSON-LD BreadcrumbList for an article: Home › Blog › its chain of topics › the
  # article.
  # @see https://developers.google.com/search/docs/appearance/structured-data/breadcrumb
  # @return [String, nil] The JSON-LD, or nil if the entry is not a published post.
  def breadcrumb_schema(content)
    return unless published_post?(content)

    crumbs = taxonomy_trail(content).map { |node| [ sanitize(node[:name]), full_url(node[:path]) ] }
    crumbs << [ sanitize(content.title), canonical_url ]
    breadcrumb_list_schema(crumbs)
  end
end
