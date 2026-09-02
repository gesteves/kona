module ArticleHelpers
  # The words per minute for the "N minute read" estimate, when READING_TIME_WPM is not a
  # correct number.
  DEFAULT_READING_TIME_WPM = 200

  # Tells if an entry is a blog post (a full Article or a Short).
  # @param entry [Object] The entry to check.
  # @return [Boolean]
  def blog_post?(entry)
    %w[Article Short].include?(entry&.entry_type)
  end

  # Tells if an entry is a published blog post, that is, not a draft. It controls the markup for
  # posts only: the article schema, the breadcrumbs, and the Open Graph article tags.
  # @param entry [Object] The entry to check.
  # @return [Boolean]
  def published_post?(entry)
    blog_post?(entry) && !entry.draft
  end

  # All the non-draft articles, the newest first. data.articles is already in publish-date order.
  # @return [Array<Object>]
  def published_articles
    memoize_by_collection(:published_articles, data.articles) { data.articles.reject(&:draft) }
  end

  # All the non-draft pages.
  # @return [Array<Object>]
  def published_pages
    memoize_by_collection(:published_pages, data.pages) { data.pages.reject(&:draft) }
  end

  # The non-draft articles that a search engine can index.
  # @return [Array<Object>]
  def indexable_articles
    memoize_by_collection(:indexable_articles, data.articles) do
      data.articles.reject { |a| a.draft || !a.index_in_search_engines }
    end
  end

  # The non-draft pages that a search engine can index.
  # @return [Array<Object>]
  def indexable_pages
    memoize_by_collection(:indexable_pages, data.pages) do
      data.pages.reject { |p| p.draft || !p.index_in_search_engines }
    end
  end

  # The publish date of an entry, after the parse.
  # @param entry [Object] The entry.
  # @return [DateTime]
  def published_datetime(entry)
    DateTime.parse(entry.published_at)
  end

  # The DOM id for an entry element, from its Contentful id. parameterize makes it lowercase.
  # @param entry [Object] The entry.
  # @param scope [String, nil] A section slug at the start of the id. It is necessary when a
  #   section can list an entry that another section on the same page also lists. With no scope,
  #   the two cards have the same id and each aria-labelledby points to the first card.
  # @return [String] For example "entry-1qxuv2jhbvrd9oqmxoneqz".
  def entry_dom_id(entry, scope: nil)
    "entry-#{scoped_entry_key(entry, scope)}"
  end

  # The DOM id for the heading of an entry. The aria-labelledby of the entry element points to it.
  # @param entry [Object] The entry.
  # @param scope [String, nil] The same as for #entry_dom_id. Give the two the same scope.
  # @return [String] For example "hed-1qxuv2jhbvrd9oqmxoneqz".
  def entry_heading_id(entry, scope: nil)
    "hed-#{scoped_entry_key(entry, scope)}"
  end

  # @return [String] The shared end of the id. With no scope, it is the Contentful id.
  def scoped_entry_key(entry, scope)
    [ scope, entry.sys.id ].compact.join("-").parameterize
  end

  # @param entry [Object] The entry.
  # @return [String, nil] The public name of the entry type.
  def entry_type(entry)
    return if entry.entry_type.blank?
    case entry.entry_type
    when "Short"
      "Post"
    else
      entry.entry_type
    end
  end

  # Makes the permalink of an article, with its publish date as the label. For a recent article,
  # the publish-date Stimulus controller puts a live relative time in its place. This is the
  # result when there is no JavaScript.
  # @param article [Object] The article.
  # @param link_class [String, nil] The class names for the <a>. Use article_click_classes for the
  #   analytics of a card. Leave it out on the page of the article: that link is the page itself.
  # @return [String] A <time> that contains an <a>, thus a machine can still read the ISO instant.
  def article_permalink_timestamp(article, link_class: nil)
    published = published_datetime(article)
    options = {
      # article.path is the source path. url_for makes the URL that directory_indexes serves.
      href: url_for(article.path),
      title: "Published at #{published.strftime('%-I:%M %p')}",
      "data-publish-date-target": "timestamp",
      class: link_class
    }
    link = content_tag :a, options do
      published.strftime("%A, %B %-e, %Y")
    end
    content_tag :time, link, datetime: published.iso8601
  end

  # ⚠️ This reads `page_content`, never `defined?(content)`. `content` is a template local, thus
  # `defined?` is always nil in the binding of a helper method. The check then gives "do not
  # hide", and each draft goes to production where a search engine can index it.
  # @return [Boolean] True if a search engine must not index the current page.
  def hide_from_search_engines?
    return true unless production?
    page = page_content
    # There is no proxied content object (the 404 page, and each other frontmatter-only
    # template). The flag then comes from the frontmatter. The default lets a search engine index
    # the page, thus an ordinary page does not change.
    return current_page.data.index_in_search_engines == false if page.nil?
    return true if page.draft
    !page.index_in_search_engines
  end

  # @return [String] The canonical URL for the current content object or page.
  def canonical_url
    page = page_content
    return page.canonical_url if page&.canonical_url.present?
    full_url(current_page.url)
  end

  # The most recent full articles. This does not include the drafts and the Shorts.
  # @param count [Integer] The number to return.
  # @param exclude [Object] An article to omit.
  # @return [Array<Object>]
  def recent_articles(count: 4, exclude: nil)
    published_articles
      .reject { |a| a.path == exclude&.path }
      .reject { |a| a.entry_type == "Short" }
      .take(count)
  end

  # The entries with the nearest meaning to this one, for the static "You May Also Like" section.
  # The order comes from data/related.json, which `rake import:related` gets from the api. The api
  # makes it from a BM25 index of the article text and from the concepts. It is the one part of the
  # section that this build cannot make from its own data.
  #
  # ⚠️ An empty result removes the section. This is correct for the three causes of an empty
  # result: the import did not run (no api, or no token), the api could not read Contentful, or
  # each neighbor that it names is now unpublished.
  # @param article [Object] The entry to find the neighbors of.
  # @param count [Integer] The number to return.
  # @return [Array<Object>] The related entries, the nearest first.
  def related_articles(article, count: 4)
    return [] unless data.respond_to?(:related)

    ids = Array(data.related[article.sys&.id])
    return [] if ids.empty?

    index = published_articles_by_id
    ids.filter_map { |id| index[id] }.take(count)
  end

  # @return [Hash{String=>Object}] The published entries by Contentful id, to find the ids in
  #   data/related.json. The app keeps the value for the life of the collection, because it
  #   calls this one time for each article page.
  def published_articles_by_id
    memoize_by_collection(:published_articles_by_id, data.articles) do
      published_articles.index_by { |a| a.sys&.id }
    end
  end

  # The most recent published entries, for the Atom feed.
  # @param count [Integer] The number to return.
  # @return [Array<Object>]
  # ⚠️ The feeds are the largest part of the build: each entry renders its intro and its body,
  # and each tag has a feed of its own. Twenty-five is what a reader needs from a feed.
  def feed_articles(count: 25)
    published_articles.take(count)
  end

  # The most recent full articles that a search engine can index, for llms.txt.
  # @param count [Integer] The number to return.
  # @return [Array<Object>]
  def llms_articles(count: 100)
    indexable_articles
      .reject { |a| a.entry_type == "Short" }
      .take(count)
  end

  # The adjacent entries in time, for the "Read next" navigation. It includes the Shorts, thus
  # the navigation works on both types of page.
  # @param article [Object] The current entry.
  # @return [Hash] { newer:, older: }. One of them is nil at each end of the archive. Both are
  #   nil if the entry is not in the published sequence, for example a draft preview.
  def adjacent_articles(article)
    sequence = published_articles
    # The app makes this index one time for each build. A scan for each article page is slower.
    positions = memoize_by_collection(:published_article_positions, data.articles) do
      sequence.each_with_index.to_h { |a, i| [ a.path, i ] }
    end

    index = positions[article.path]
    return { newer: nil, older: nil } if index.nil?

    { newer: index.positive? ? sequence[index - 1] : nil, older: sequence[index + 1] }
  end

  # Makes the JSON-LD BlogPosting schema for an article.
  # @param content [Object] The article.
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
      card_url = generate_open_graph_image_url(current_page.url, content.sys&.published_version)
      schema["image"] = [ image_object(card_url, 1200, 630) ]
    end
    schema.to_json
  end

  # Makes the JSON-LD BreadcrumbList for an article: Home › Blog › its chain of topics › the
  # article.
  # @param content [Object] The article.
  # @see https://developers.google.com/search/docs/appearance/structured-data/breadcrumb
  # @return [String, nil] The JSON-LD, or nil if the entry is not a published post.
  def breadcrumb_schema(content)
    return unless published_post?(content)

    crumbs = taxonomy_trail(content).map { |node| [ sanitize(node[:name]), full_url(node[:path]) ] }
    crumbs << [ sanitize(content.title), canonical_url ]
    breadcrumb_list_schema(crumbs)
  end

  # The chain of parents of the most deeply nested concept of an article, in the two schemes. If
  # two concepts are at the same depth, the number of articles in the archive of the concept
  # selects one.
  # @param content [Object] The article.
  # @return [Array<Hash>] The [{ id:, name:, path: }] items, the root first, or [] if the article
  #   has no tags.
  def taxonomy_trail(content)
    tags = Array(content.contentful_metadata&.tags)
    return [] if tags.empty?

    index = taxonomy_index
    chains = tags.map { |t| concept_chain(t.id) }.reject(&:empty?)
    return [] if chains.empty?

    chains.max_by { |chain| [ chain.length, index.dig(chain.last[:id], :count).to_i ] }
  end

  # The chain of parents of a concept id, from data.tags. It starts at the root and includes the
  # concept.
  # @return [Array<Hash>] [{ id:, name:, path: }], or [] if the id is not a known concept.
  def concept_chain(id)
    index = taxonomy_index
    chain = []
    cur = id
    seen = {}
    while cur && (node = index[cur]) && !seen[cur]
      seen[cur] = true
      chain.unshift({ id: cur, name: node[:name], path: node[:path] })
      cur = node[:parent_id]
    end
    chain
  end

  # Concept id => { name:, path:, parent_id:, scheme:, count: }, from the tag pages that the
  # build makes. Each parent has a page, thus each chain is always complete. The app keeps the
  # value for each render.
  # @return [Hash{String=>Hash}]
  def taxonomy_index
    @taxonomy_index ||= Array(data.tags).each_with_object({}) do |entry, index|
      tag = entry.tag
      # Use entry_count, not count: `count` is Hash#count on the Mash, the number of keys.
      index[tag.id] = { name: tag.name, path: tag.path, parent_id: tag.parent_id, scheme: tag.scheme, count: tag.entry_count }
    end
  end

  # The separator between the tag links in a breadcrumb chain.
  TAG_SEPARATOR = '<span class="entry__tag-separator" aria-hidden="true">/</span>'.freeze

  # The tag icon for a tag list: one tag gets the "tag" icon, more than one gets "tags".
  # @param count [Integer] The number of tags in the list.
  # @return [String, nil] The icon SVG.
  def tag_list_icon(count)
    icon_svg("classic", "light", count == 1 ? "tag" : "tags")
  end

  # Renders a list of tag links, that is, [label, path] pairs. Each link is a role="listitem"
  # span, and a slash goes between the spans. The article meta line and the tag-archive header
  # both use this.
  # @param links [Array<Array(String, String)>] The [label, path] pairs.
  # @return [String] The markup, joined.
  def tag_chain_links(links)
    links.map { |label, path| content_tag(:span, link_to(label, path), role: "listitem") }.join(TAG_SEPARATOR)
  end

  # The "Draft" badge on the meta line of an unpublished entry.
  # @return [String] A highlight span with the typewriter icon.
  def draft_badge
    %(<span class="entry__highlight">#{icon_svg("classic", "regular", "typewriter")} Draft</span>)
  end

  # Counts the words in the intro and the body of an article. The app keeps the value for each
  # entry, because the removal of the markup is slow and each page calls this more than one time.
  # @param article [Object] The article.
  # @return [Integer] The number of words.
  def article_word_count(article)
    id = article.sys&.id
    return compute_article_word_count(article) if id.blank?

    # The store is by collection, thus one count serves each page that renders the entry.
    store = memoize_by_collection(:article_word_counts, (data.articles if respond_to?(:data))) { {} }
    return store[id] if store.key?(id)

    store[id] = compute_article_word_count(article)
  end

  # @see #article_word_count
  def compute_article_word_count(article)
    plain_text = sanitize([ article.intro, article.body ].reject(&:blank?).join("\n\n"), escape_html_entities: true)
    plain_text.split(/\s+/).size
  end

  # The estimated reading time for an article, in full minutes. It rounds up.
  # @param article [Object] The article.
  # @return [Integer] The reading time in minutes.
  def reading_time_minutes(article)
    # ⚠️ Do not use ENV.fetch with a default. It gives the default only when the key is ABSENT.
    # A CI variable with no value becomes an empty string, which is available but blank.
    # `''.to_i` is 0, and a division by 0 raises FloatDomainError on each article page.
    wpm = ENV["READING_TIME_WPM"].to_i
    wpm = DEFAULT_READING_TIME_WPM unless wpm.positive?
    (article_word_count(article) / wpm.to_f).ceil
  end

  # @param article [Object] The article.
  # @return [String] The reading time as text, for example "A 4-minute read".
  def reading_time(article)
    minutes = reading_time_minutes(article)
    # A number that starts with a vowel sound when you speak it takes "An".
    indefinite_article = minutes.humanize.match?(/^(eight|eleven)/i) ? "An" : "A"
    "#{indefinite_article} #{minutes}-minute read"
  end

  # The other race reports with the same race concept as this article, the newest first. The app
  # keeps the value, because recirculation_section reads it and the title needs it again.
  # @param article [Object] The current article.
  # @param count [Integer] The number to return.
  # @return [Array<Object>]
  def related_race_reports(article, count: 4)
    race_id = race_concept_id(article)
    return [] if race_id.nil?

    Array(race_reports_by_race[race_id])
      .reject { |a| a.slug == article.slug }
      .take(count)
  end

  # Each full race report, by its race concept, the newest first. The build makes it one time:
  # each article page reads it, and a scan of the archive for each page grows with the square of
  # the archive.
  # @return [Hash{String => Array<Object>}]
  def race_reports_by_race
    memoize_by_collection(:race_reports_by_race, (data.articles if respond_to?(:data))) do
      published_articles
        .select { |a| race_report?(a) && a.entry_type != "Short" }
        .group_by { |a| race_concept_id(a) }
        .tap { |index| index.delete(nil) }
        .transform_values { |reports| reports.sort_by { |a| -published_datetime(a).to_i } }
    end
  end

  # The entries for the two recirculation sections of an article: the reports of the same race, and
  # then the related entries.
  #
  # ⚠️ The two sections excluded each other before, thus a race with only one or two other reports
  # gave one or two cards where four were possible. Race reports are the largest group on the site,
  # thus that applied to most of them. The two now render together, and the dedup below is what
  # makes that safe: a report of the same race is often also a near entry by meaning, and the same
  # card two times would give two DOM ids that are the same.
  # @param article [Object] The article.
  # @param count [Integer] The number of cards in each section.
  # @return [Hash] { reports:, related: }. An empty list renders no section.
  def recirculation_sections(article, count: 4)
    reports = related_race_reports(article, count: count)

    seen = reports.filter_map { |a| a.sys&.id }.to_set
    seen << article.sys&.id
    related = related_articles(article, count: count + reports.size)
      .reject { |a| seen.include?(a.sys&.id) }
      .take(count)

    { reports: reports, related: related }
  end

  # The id of the race concept of an article: its most deeply nested Sports concept at the race
  # level or below it (discipline › distance › race, thus the chain length is 3 or more). It
  # controls the groups of race reports.
  # @param article [Object] The article.
  # @return [String, nil]
  def race_concept_id(article)
    Array(article.contentful_metadata&.tags)
      .select { |t| t.scheme == "sports" }
      .map { |t| [ t.id, concept_chain(t.id).length ] }
      .select { |_id, depth| depth >= 3 }
      .max_by { |_id, depth| depth }
      &.first
  end

  # Tells if an article has the race-report tag. Thus a race preview with the same race concept
  # cannot go into the group of race reports.
  # @param article [Object] The article.
  # @return [Boolean]
  def race_report?(article)
    Array(article.contentful_metadata&.tags).any? { |t| t.id == "race-reports" }
  end

  # The concepts of the article as breadcrumb chains, one chain for each leaf concept. The code
  # reads each chain through the full taxonomy, then keeps only the concepts that the article
  # has. Thus it removes a concept in the middle that the article does not have, and the chain
  # stays complete. The most deeply nested chain is first, and Sports goes before Topics at the
  # same depth.
  # @param article [Object] The article.
  # @return [Array<Array>] One array of tags for each chain, from the root to the leaf.
  def tag_breadcrumb_chains(article)
    tags = Array(article.contentful_metadata&.tags)
    return [] if tags.empty?

    by_id = tags.to_h { |t| [ t.id, t ] }
    chain_ids = tags.to_h { |t| [ t.id, concept_chain(t.id).map { |n| n[:id] } ] }
    ancestor_ids = chain_ids.values.flat_map { |ids| ids[0...-1] }.to_set
    leaves = tags.reject { |t| ancestor_ids.include?(t.id) }

    # ⚠️ Reject the empty chains. A concept with no published article gets no tag page, thus it is
    # absent from the taxonomy and `concept_chain` gives []. A draft can hold such a concept.
    chains = leaves.map { |leaf| chain_ids[leaf.id].filter_map { |id| by_id[id] } }.reject(&:empty?)
    chains.sort_by { |chain| [ -chain.length, chain.first.scheme == "sports" ? 0 : 1, chain.last.short_name.to_s ] }
  end

  # The concepts of the article for the meta line: the breadcrumb chains as one flat list, with
  # each concept one time. Two chains that share a parent give that parent one time, and the
  # children of that parent stay together.
  # @param article [Object] The article.
  # @return [Array<Object>] The tags, a parent before its children.
  def tag_breadcrumb_concepts(article)
    flatten_concept_chains(tag_breadcrumb_chains(article))
  end

  private

  # Walks the chains as a tree and gives the concepts at one depth and below, a parent before its
  # children. A concept that more than one chain holds goes into the list one time.
  # @param chains [Array<Array>] The chains, from the root to the leaf.
  # @param depth [Integer] The position in a chain to group on.
  # @return [Array<Object>] The tags.
  def flatten_concept_chains(chains, depth = 0)
    chains.reject { |chain| chain.length <= depth }
          .group_by { |chain| chain[depth].id }
          .flat_map { |_id, group| [ group.first[depth] ] + flatten_concept_chains(group, depth + 1) }
  end
end
