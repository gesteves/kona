module ArticleHelpers
  # Whether an entry is a blog post (a full Article or a Short).
  # @param entry [Object] The entry to check.
  # @return [Boolean]
  def blog_post?(entry)
    %w[Article Short].include?(entry&.entry_type)
  end

  # Whether an entry is a published (non-draft) blog post. Guards post-only markup like the
  # article schema, breadcrumbs, and Open Graph article tags.
  # @param entry [Object] The entry to check.
  # @return [Boolean]
  def published_post?(entry)
    blog_post?(entry) && !entry.draft
  end

  # All non-draft articles, newest first (data.articles is already sorted by publish date).
  # @return [Array<Object>]
  def published_articles
    memoize_by_collection(:published_articles, data.articles) { data.articles.reject(&:draft) }
  end

  # All non-draft pages.
  # @return [Array<Object>]
  def published_pages
    memoize_by_collection(:published_pages, data.pages) { data.pages.reject(&:draft) }
  end

  # Non-draft articles that may be indexed by search engines.
  # @return [Array<Object>]
  def indexable_articles
    memoize_by_collection(:indexable_articles, data.articles) do
      data.articles.reject { |a| a.draft || !a.index_in_search_engines }
    end
  end

  # Non-draft pages that may be indexed by search engines.
  # @return [Array<Object>]
  def indexable_pages
    memoize_by_collection(:indexable_pages, data.pages) do
      data.pages.reject { |p| p.draft || !p.index_in_search_engines }
    end
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

  # @param entry [Object] The entry.
  # @return [String, nil] The publicly-visible name for the entry's type.
  def entry_type(entry)
    return if entry.entry_type.blank?
    case entry.entry_type
    when 'Short'
      'Post'
    else
      entry.entry_type
    end
  end

  # Builds the article's permalink, labelled with its publish date. The publish-date Stimulus
  # controller swaps in a live relative timestamp for recent articles; this is the no-JS
  # fallback.
  # @param article [Object] The article.
  # @return [String] A <time> wrapping an <a>, so the ISO instant stays machine-readable.
  def article_permalink_timestamp(article)
    published = published_datetime(article)
    options = {
      # article.path is the source path; url_for turns it into the URL directory_indexes serves.
      href: url_for(article.path),
      title: "Published at #{published.strftime('%-I:%M %p')}",
      "data-publish-date-target": "timestamp"
    }
    link = content_tag :a, options do
      published.strftime('%A, %B %-e, %Y')
    end
    content_tag :time, link, datetime: published.iso8601
  end

  # @return [Boolean] Whether the current page should be hidden from search engines.
  def hide_from_search_engines?
    return true unless production?
    return false unless defined?(content)
    return true if content.draft
    !content.index_in_search_engines
  end

  # @return [String] The canonical URL for the current content object or page.
  def canonical_url
    return content.canonical_url if defined?(content) && content&.canonical_url.present?
    full_url(current_page.url)
  end

  # The most recent full articles, excluding drafts and Shorts.
  # @param count [Integer] How many to return.
  # @param exclude [Object] An article to omit.
  # @return [Array<Object>]
  def recent_articles(count: 4, exclude: nil)
    published_articles
      .reject { |a| a.path == exclude&.path }
      .reject { |a| a.entry_type == 'Short' }
      .take(count)
  end

  # The most recent published entries, for the Atom feed.
  # @param count [Integer] How many to return.
  # @return [Array<Object>]
  def feed_articles(count: 100)
    published_articles.take(count)
  end

  # The most recent indexable full articles, for llms.txt.
  # @param count [Integer] How many to return.
  # @return [Array<Object>]
  def llms_articles(count: 100)
    indexable_articles
      .reject { |a| a.entry_type == 'Short' }
      .take(count)
  end

  # The chronologically adjacent entries, for "Read next" navigation. Includes Shorts, so the
  # nav works on both kinds of page.
  # @param article [Object] The current entry.
  # @return [Hash] { newer:, older: }; either is nil at the ends of the archive, and both are
  #   when the entry isn't in the published sequence (e.g. a draft preview).
  def adjacent_articles(article)
    sequence = published_articles
    # Indexed once per build rather than scanned per article page, which was quadratic.
    positions = memoize_by_collection(:published_article_positions, data.articles) do
      sequence.each_with_index.to_h { |a, i| [a.path, i] }
    end

    index = positions[article.path]
    return { newer: nil, older: nil } if index.nil?

    { newer: index.positive? ? sequence[index - 1] : nil, older: sequence[index + 1] }
  end

  # Builds the JSON-LD BlogPosting schema for an article.
  # @param content [Object] The article.
  # @see https://developers.google.com/search/docs/appearance/structured-data/article
  # @return [String, nil] JSON-LD, or nil for a draft.
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
      # Referenced by @id so consumers resolve to the single sitewide entity for each.
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
      schema["keywords"] = tags.flat_map { |t| [t.name, *Array(t.synonyms)] }.uniq
      # Prefer the content-type concept, then any Topics concept, then whatever's first.
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
      # No cover image: fall back to the generated Open Graph card, so the BlogPosting still
      # carries an image.
      card_url = generate_open_graph_image_url(current_page.url, content.sys&.published_version)
      schema["image"] = [image_object(card_url, 1200, 630)]
    end
    schema.to_json
  end

  # Builds the JSON-LD BreadcrumbList for an article: Home › Blog › its topic trail › the
  # article.
  # @param content [Object] The article.
  # @see https://developers.google.com/search/docs/appearance/structured-data/breadcrumb
  # @return [String, nil] JSON-LD, or nil unless the entry is a published post.
  def breadcrumb_schema(content)
    return unless published_post?(content)

    crumbs = taxonomy_trail(content).map { |node| [sanitize(node[:name]), full_url(node[:path])] }
    crumbs << [sanitize(content.title), canonical_url]
    breadcrumb_list_schema(crumbs)
  end

  # The ancestor chain of an article's deepest-nested concept across either scheme, tie-broken
  # by the concept's archive article count.
  # @param content [Object] The article.
  # @return [Array<Hash>] Ordered [{ id:, name:, path: }] root-first, or [] when untagged.
  def taxonomy_trail(content)
    tags = Array(content.contentful_metadata&.tags)
    return [] if tags.empty?

    index = taxonomy_index
    chains = tags.map { |t| concept_chain(t.id) }.reject(&:empty?)
    return [] if chains.empty?

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

  # Concept id => { name:, path:, parent_id:, scheme:, count: }, built from the generated tag
  # pages. Every ancestor has a page, so chains always resolve fully. Memoized per render.
  # @return [Hash{String=>Hash}]
  def taxonomy_index
    @taxonomy_index ||= Array(data.tags).each_with_object({}) do |entry, index|
      tag = entry.tag
      # entry_count, not count: `count` is Hash#count on the Mash, i.e. the number of keys.
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

  # Counts the words in an article's intro and body. Memoized per entry, since sanitizing the
  # whole article is expensive and this is called several times per page.
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

  # @param article [Object] The article.
  # @return [String] The reading time as prose, e.g. "A 4-minute read".
  def reading_time(article)
    minutes = reading_time_minutes(article)
    # Numbers whose spoken form starts with a vowel sound take "An".
    indefinite_article = minutes.humanize.match?(/^(eight|eleven)/i) ? 'An' : 'A'
    "#{indefinite_article} #{minutes}-minute read"
  end

  # Other race reports sharing this article's race concept, newest first. Memoized, since the
  # template consults it once to pick a section and the partial again to render it.
  # @param article [Object] The current article.
  # @param count [Integer] How many to return.
  # @return [Array<Object>]
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

  # The id of an article's race concept: its deepest Sports concept at or below the race level
  # (discipline › distance › race, so chain length ≥ 3). Drives race-report grouping.
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

  # Whether an article is tagged as a race report, so a race preview sharing the same race
  # concept can't slip into the race-report grouping.
  # @param article [Object] The article.
  # @return [Boolean]
  def race_report?(article)
    Array(article.contentful_metadata&.tags).any? { |t| t.id == 'race-reports' }
  end

  # The article's concepts as breadcrumb chains, one per leaf concept. Chains are walked through
  # the full taxonomy then filtered to the concepts the article carries, so an unassigned
  # intermediate is dropped without splitting the chain. Sorted deepest-first, Sports before
  # Topics on a tie.
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
