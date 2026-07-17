module ArticleHelpers
  # Whether an entry is a blog post (a full Article or a Short).
  # @param entry [Object] The entry to check.
  # @return [Boolean]
  def blog_post?(entry)
    %w[Article Short].include?(entry&.entry_type)
  end

  # Whether an entry is a published (non-draft) blog post — the guard for post-only markup
  # like the article schema, breadcrumbs, and Open Graph article tags.
  # @param entry [Object] The entry to check.
  # @return [Boolean]
  def published_post?(entry)
    blog_post?(entry) && !entry.draft
  end

  # All non-draft articles, newest first (data.articles is already sorted by publish date).
  # @return [Array<Object>]
  def published_articles
    data.articles.reject(&:draft)
  end

  # All non-draft pages.
  # @return [Array<Object>]
  def published_pages
    data.pages.reject(&:draft)
  end

  # Non-draft articles that may be indexed by search engines.
  # @return [Array<Object>]
  def indexable_articles
    data.articles.reject { |a| a.draft || !a.index_in_search_engines }
  end

  # Non-draft pages that may be indexed by search engines.
  # @return [Array<Object>]
  def indexable_pages
    data.pages.reject { |p| p.draft || !p.index_in_search_engines }
  end

  # An entry's publish date, parsed.
  # @param entry [Object] The entry.
  # @return [DateTime]
  def published_datetime(entry)
    DateTime.parse(entry.published_at)
  end

  # The DOM id for an entry element, from its Contentful id (parameterize lowercases it).
  # @param entry [Object] The entry.
  # @return [String] e.g. "entry-1qxuv2jhbvrd9oqmxoneqz".
  def entry_dom_id(entry)
    "entry-#{entry.sys.id.parameterize}"
  end

  # The DOM id for an entry's heading, referenced by the entry element's aria-labelledby.
  # @param entry [Object] The entry.
  # @return [String] e.g. "hed-1qxuv2jhbvrd9oqmxoneqz".
  def entry_heading_id(entry)
    "hed-#{entry.sys.id.parameterize}"
  end

  # Returns the publicly-visible name for an entry type
  # @param entry [Object] The entry to check.
  # @return [String] The name of the entry type
  def entry_type(entry)
    return if entry.entry_type.blank?
    case entry.entry_type
    when 'Short'
      'Post'
    else
      entry.entry_type
    end
  end

  # Returns a permalink anchor tag for the article, with the date it was published as its text.
  # The publish-date Stimulus controller swaps in a live relative timestamp client-side for recent
  # articles (so it stays correct without a rebuild); the absolute date here is the no-JS fallback.
  # @param article [Object] The article.
  # @return [String] An <a> tag linking to the article, with the publish date as the text.
  def article_permalink_timestamp(article)
    published = published_datetime(article)
    options = {
      href: article.path,
      title: "Published at #{published.strftime('%-I:%M %p')}",
      "data-publish-date-target": "timestamp"
    }
    link = content_tag :a, options do
      published.strftime('%A, %B %-e, %Y')
    end
    # Wrap in a <time> so the ISO publish instant is machine-readable. The Stimulus controller
    # swaps the inner <a>'s content for recent posts; this wrapper (and its datetime) is untouched.
    content_tag :time, link, datetime: published.iso8601
  end

  # Determines whether the content should be hidden from search engines.
  # @return [Boolean] Returns true if the page should be hidden from search engines.
  def hide_from_search_engines?
    return true unless production?
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

  # Retrieves a specified number of the most recent articles, excluding drafts and short entries.
  # @param count [Integer] (Optional) The number of recent articles to return.
  # @param exclude [Object] (Optional) An article to exclude from the results.
  # @return [Array<Object>] An array of the most recent articles, up to the specified count.
  def recent_articles(count: 4, exclude: nil)
    published_articles
      .reject { |a| a.path == exclude&.path } # Exclude the given article, if applicable
      .reject { |a| a.entry_type == 'Short' } # Exclude short posts
      .take(count)
  end

  # Retrieves a specified number of the most recent articles for the RSS feed, excluding drafts.
  # @param count [Integer] (Optional) The number of recent articles to return. Default is 100.
  # @return [Array<Object>] An array of the most recent articles, up to the specified count.
  def feed_articles(count: 100)
    published_articles.take(count)
  end

  # Retrieves the articles to list in llms.txt: full articles only (no shorts), indexable, and
  # newest first (data.articles is already sorted by publish date, descending).
  # @param count [Integer] (Optional) The maximum number of articles to return. Default is 100.
  # @return [Array<Object>] An array of the most recent indexable full articles.
  def llms_articles(count: 100)
    indexable_articles
      .reject { |a| a.entry_type == 'Short' }
      .take(count)
  end

  # Returns the chronologically adjacent entries for sequential "Read next" navigation.
  # data.articles is sorted newest-first, so the entry before the current one is the newer
  # neighbor and the entry after it is the older neighbor. Traverses all published entries
  # (Shorts included), so the nav works on both full-article and Short pages.
  # @param article [Object] The current entry.
  # @return [Hash] { newer:, older: } — either value is nil at the ends of the archive (or both
  #   when the entry isn't in the published sequence, e.g. a draft preview).
  def adjacent_articles(article)
    sequence = published_articles
    index = sequence.index { |a| a.path == article.path }
    return { newer: nil, older: nil } if index.nil?

    { newer: index.positive? ? sequence[index - 1] : nil, older: sequence[index + 1] }
  end

  # Generates a JSON-LD schema string for an article, based on the provided content.
  # @param content [Object] An object containing the article's data.
  # @see https://developers.google.com/search/docs/appearance/structured-data/article
  # @return [String] A JSON-LD formatted string representing the article's schema.
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
      # Reference the sitewide entity-graph nodes (partials/schema/_site) by @id rather than
      # duplicating them, so consumers resolve the author and publisher to a single entity each.
      "author": { "@id": schema_entity_id('person', path: '/about') },
      "publisher": { "@id": schema_entity_id('organization') },
      "isPartOf": { "@id": schema_entity_id('website') },
      "mainEntityOfPage": {
        "@type": "WebPage",
        "@id": canonical_url
      }
    }
    tags = Array(content.contentful_metadata&.tags)
    if tags.present?
      # Each concept's name plus its synonyms (altLabels), deduped, as keywords.
      schema["keywords"] = tags.flat_map { |t| [t.name, *Array(t.synonyms)] }.uniq
      # articleSection: the content-type concept, else any Topics concept, else the first tag.
      section = tags.find { |t| %w[race-reports news reviews].include?(t.id) } ||
                tags.find { |t| t.scheme == 'topics' } || tags.first
      schema["articleSection"] = section.name
    end
    if content&.cover_image&.url.present?
      schema["image"] = ["1000x1000", "1600x900", "1600x1200"].map do |s|
        w, h = s.split('x').map(&:to_i)
        image_object(cdn_image_url(content.cover_image.url, { w: w, h: h, fit: 'cover' }), w, h)
      end
    else
      # No cover image (typical for Shorts): fall back to the generated Open Graph card — the
      # same 1200×630 image used for social embeds — so the BlogPosting still carries an image.
      schema["image"] = [image_object(generate_open_graph_image_url(full_url(current_page.url), content.sys.published_version), 1200, 630)]
    end
    schema.to_json
  end

  # Generates a JSON-LD schema string for breadcrumb navigation, based on the provided content.
  # @param content [Object] An object containing the article's data.
  # @see https://developers.google.com/search/docs/appearance/structured-data/breadcrumb
  # @return [String] A JSON-LD formatted string representing the breadcrumb schema.
  def breadcrumb_schema(content)
    return unless published_post?(content)

    # The article's topic trail (Triathlon > Ironman 70.3, …) sits between Blog and the article.
    crumbs = taxonomy_trail(content).map { |node| [sanitize(node[:name]), full_url(node[:path])] }
    crumbs << [sanitize(content.title), canonical_url]
    breadcrumb_list_schema(crumbs)
  end

  # The taxonomy trail for an article's breadcrumb: the ancestor chain (root → … → concept) of
  # the article's deepest-nested concept across either scheme, tie-broken by the concept's
  # archive popularity (article count). So a race report gets its Sports chain (Triathlon >
  # Half Distance > the race), while a post with only Topics concepts still gets a trail (e.g.
  # Tech > Gear, or News). Returns [] when the article has no taxonomy.
  # @param content [Object] The article.
  # @return [Array<Hash>] Ordered [{ id:, name:, path: }] from root to the chosen concept.
  def taxonomy_trail(content)
    tags = Array(content.contentful_metadata&.tags)
    return [] if tags.empty?

    index = taxonomy_index
    chains = tags.map { |t| concept_chain(t.id) }.reject(&:empty?)
    return [] if chains.empty?

    # Deepest chain wins; ties broken by the deepest concept's archive article count.
    chains.max_by { |chain| [chain.length, index.dig(chain.last[:id], :count).to_i] }
  end

  # The ancestor chain of a concept id, root-first and inclusive, resolved from data.tags.
  # @return [Array<Hash>] [{ id:, name:, path: }] or [] if the id isn't a known concept.
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

  # Concept id => { name:, path:, parent_id: }, built from the generated tag pages (data.tags).
  # Ancestors always have a page (they inherit every descendant's articles), so the chain
  # resolves fully. Memoized per render.
  # @return [Hash{String=>Hash}]
  def taxonomy_index
    @taxonomy_index ||= Array(data.tags).each_with_object({}) do |entry, index|
      tag = entry.tag
      # Read `tag.entry_count`, not `tag.count`: `count` is Hash#count on the Mash (the number
      # of keys), so it would silently return a constant instead of the archive's article total.
      index[tag.id] = { name: tag.name, path: tag.path, parent_id: tag.parent_id, scheme: tag.scheme, count: tag.entry_count }
    end
  end

  # The separator rendered between tag links in a breadcrumb chain.
  TAG_SEPARATOR = '<span class="entry__tag-separator" aria-hidden="true">/</span>'.freeze

  # The tag icon for a tag list: a single tag gets the "tag" icon, several get "tags".
  # @param count [Integer] How many tags the list shows.
  # @return [String, nil] The icon SVG.
  def tag_list_icon(count)
    icon_svg("classic", "light", count == 1 ? "tag" : "tags")
  end

  # Renders breadcrumb chains of tag links — [label, path] pairs — as slash-separated
  # role="listitem" spans (both within and between chains). Shared by the article meta line
  # and the tag-archive header.
  # @param chains [Array<Array<Array(String, String)>>] Chains of [label, path] pairs.
  # @return [String] The joined markup.
  def tag_chain_links(chains)
    chains.map do |chain|
      chain.map { |label, path| content_tag(:span, link_to(label, path), role: 'listitem') }.join(TAG_SEPARATOR)
    end.join(TAG_SEPARATOR)
  end

  # The "Draft" badge shown on unpublished entries' meta lines.
  # @return [String] A highlight span with the typewriter icon.
  def draft_badge
    %(<span class="entry__highlight">#{icon_svg("classic", "regular", "typewriter")} Draft</span>)
  end

  # Counts the words in an article's prose (intro + body, as plain text). Shared by the reading-time
  # estimate and the BlogPosting schema's wordCount. Memoized per entry — sanitizing the whole
  # article is expensive and this gets called several times per page (reading time + schema).
  # @param article [Object] The article.
  # @return [Integer] The number of words.
  def article_word_count(article)
    memoize_by_key(:@article_word_counts, article.sys&.id) do
      compute_article_word_count(article)
    end
  end

  # @see #article_word_count
  def compute_article_word_count(article)
    plain_text = sanitize([article.intro, article.body].reject(&:blank?).join("\n\n"), escape_html_entities: true)
    plain_text.split(/\s+/).size
  end

  # The estimated reading time for an article, in whole minutes (rounded up).
  # @param article [Object] The article.
  # @return [Integer] Reading time in minutes.
  def reading_time_minutes(article)
    wpm = ENV.fetch('READING_TIME_WPM', 200).to_i
    (article_word_count(article) / wpm.to_f).ceil
  end

  # Formats the reading time for an article.
  # @param article [Object] The article to calculate the reading time for.
  # @return [String] The formatted reading time.
  def reading_time(article)
    minutes = reading_time_minutes(article)
    # Numbers whose spoken form starts with a vowel sound take "An": eight, eighteen,
    # eighty…, eight hundred…, eleven, eleven hundred….
    indefinite_article = minutes.humanize.match?(/^(eight|eleven)/i) ? 'An' : 'A'
    "#{indefinite_article} #{minutes}-minute read"
  end

  # Finds other race reports for the same race as the current article, grouped by the shared
  # Races-branch concept. Memoized — the article template consults this once to pick a section
  # and the partial again to render it.
  # @param article [Object] The current article to find race reports for.
  # @param count [Integer] (Optional) The number of race reports to return.
  # @return [Array<Object>] A list of race reports for the same race, sorted by publication date in reverse chronological order.
  def related_race_reports(article, count: 4)
    race_id = race_concept_id(article)
    return [] if race_id.nil?

    memoize_by_key(:@related_race_reports, [article.slug, count]) do
      published_articles
        .select { |a| race_report?(a) && race_concept_id(a) == race_id }
        .reject { |a| a.slug == article.slug }
        .reject { |a| a.entry_type == 'Short' }
        .sort_by { |a| -published_datetime(a).to_i }
        .take(count)
    end
  end

  # The id of an article's race concept — its deepest Sports concept nested below the distance
  # level (a specific race sits at discipline › distance › race, chain length ≥ 3) — or nil.
  # Drives "More Reports From This Race" grouping.
  # @param article [Object] The article.
  # @return [String, nil]
  def race_concept_id(article)
    Array(article.contentful_metadata&.tags)
      .select { |t| t.scheme == 'sports' }
      .map { |t| [t.id, concept_chain(t.id).length] }
      .select { |_id, depth| depth >= 3 }
      .max_by { |_id, depth| depth }
      &.first
  end

  # Whether an article is tagged as a race report. Guards the race-report grouping so a
  # non-report article that happens to share a race concept (e.g. a race preview) can't
  # slip into "More Reports From This Race".
  # @param article [Object] The article.
  # @return [Boolean]
  def race_report?(article)
    Array(article.contentful_metadata&.tags).any? { |t| t.id == 'race-reports' }
  end

  # The article's concept chips as breadcrumb chains: each leaf concept's ancestor chain
  # (root → leaf), for rendering as "Triathlon / Half Distance / <race> / Race Reports". The
  # chain is walked through the FULL taxonomy (`concept_chain`), then filtered to the concepts
  # the article actually carries — so an unassigned intermediate (e.g. an "Other" bucket the
  # author skipped) is dropped without splitting the chain. A leaf is a carried concept that
  # isn't an ancestor of another carried concept. Chains sort deepest-first (Sports before
  # Topics on a tie).
  # @param article [Object] The article.
  # @return [Array<Array>] One array of tags per chain, ordered root → leaf.
  def tag_breadcrumb_chains(article)
    tags = Array(article.contentful_metadata&.tags)
    return [] if tags.empty?

    by_id = tags.to_h { |t| [t.id, t] }
    chain_ids = tags.to_h { |t| [t.id, concept_chain(t.id).map { |n| n[:id] }] }
    ancestor_ids = chain_ids.values.flat_map { |ids| ids[0...-1] }.to_set
    leaves = tags.reject { |t| ancestor_ids.include?(t.id) }

    chains = leaves.map { |leaf| chain_ids[leaf.id].filter_map { |id| by_id[id] } }
    chains.sort_by { |chain| [-chain.length, chain.first.scheme == 'sports' ? 0 : 1, chain.last.short_name.to_s] }
  end
end
