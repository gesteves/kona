module ArticleHelpers
  # The words per minute for the "N minute read" estimate, when READING_TIME_WPM is not a
  # correct number.
  DEFAULT_READING_TIME_WPM = 200

  # Tells if an entry is a blog post (a full Article or a Short).
  def blog_post?(entry)
    %w[Article Short].include?(entry&.entry_type)
  end

  # Tells if an entry is a published blog post, that is, not a draft. It controls the markup of a
  # published post only: the article schema, the breadcrumbs, the standard.site document link, and
  # the link to the Markdown copy.
  def published_post?(entry)
    blog_post?(entry) && !entry.draft
  end

  # All the non-draft articles, the newest first. data.articles is already in publish-date order.
  # @return [Array<Object>]
  def published_articles
    memoize_by_collection(:published_articles, data.articles) { data.articles.reject(&:draft) }
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
  # @return [DateTime]
  def published_datetime(entry)
    DateTime.parse(entry.published_at)
  end

  # The DOM id for an entry element, from its Contentful id. parameterize makes it lowercase.
  # @param scope [String, nil] A section slug at the start of the id. It is necessary when a
  #   section can list an entry that another section on the same page also lists. With no scope,
  #   the two cards have the same id and each aria-labelledby points to the first card.
  # @return [String] For example "entry-1qxuv2jhbvrd9oqmxoneqz".
  def entry_dom_id(entry, scope: nil)
    "entry-#{scoped_entry_key(entry, scope)}"
  end

  # The DOM id for the heading of an entry. The aria-labelledby of the entry element points to it.
  # @param scope [String, nil] The same as for #entry_dom_id. Give the two the same scope.
  # @return [String] For example "hed-1qxuv2jhbvrd9oqmxoneqz".
  def entry_heading_id(entry, scope: nil)
    "hed-#{scoped_entry_key(entry, scope)}"
  end

  # @return [String] The shared end of the id. With no scope, it is the Contentful id.
  def scoped_entry_key(entry, scope)
    [ scope, entry.sys.id ].compact.join("-").parameterize
  end

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
  # @return [Array<Object>]
  def recent_articles(count: 4, exclude: nil)
    published_articles
      .reject { |a| a.path == exclude&.path }
      .reject { |a| a.entry_type == "Short" }
      .take(count)
  end

  # The most recent published entries, for the Atom feed.
  # ⚠️ The feeds are the largest part of the build: each entry renders its intro and its body,
  # and each tag has a feed of its own. Twenty-five is what a reader needs from a feed.
  # @return [Array<Object>]
  def feed_articles(count: 25)
    published_articles.take(count)
  end

  # The most recent full articles that a search engine can index, for llms.txt.
  # @return [Array<Object>]
  def llms_articles(count: 100)
    indexable_articles
      .reject { |a| a.entry_type == "Short" }
      .take(count)
  end

  # The "Draft" badge on the meta line of an unpublished entry.
  # @return [String] A highlight span with the typewriter icon.
  def draft_badge
    %(<span class="entry__highlight">#{icon_svg("classic", "regular", "typewriter")} Draft</span>)
  end

  # Counts the words in the intro and the body of an article. The app keeps the value for each
  # entry, because the removal of the markup is slow and each page calls this more than one time.
  def article_word_count(article)
    memoize_entry(:article_word_counts, article.sys&.id, (data.articles if respond_to?(:data))) do
      compute_article_word_count(article)
    end
  end

  # @see #article_word_count
  def compute_article_word_count(article)
    entry_fragment(article).text.split(/\s+/).reject(&:empty?).size
  end

  # The estimated reading time for an article, in full minutes. It rounds up.
  def reading_time_minutes(article)
    # ⚠️ Do not use ENV.fetch with a default. A CI variable with no value is an empty string, and
    # not an absent key. `''.to_i` is 0, and a division by 0 raises FloatDomainError on each
    # article page.
    wpm = ENV["READING_TIME_WPM"].to_i
    wpm = DEFAULT_READING_TIME_WPM unless wpm.positive?
    (article_word_count(article) / wpm.to_f).ceil
  end

  # @return [String] The reading time as text, for example "A 4-minute read".
  def reading_time(article)
    minutes = reading_time_minutes(article)
    # A number that starts with a vowel sound when you speak it takes "An".
    indefinite_article = minutes.humanize.match?(/^(eight|eleven)/i) ? "An" : "A"
    "#{indefinite_article} #{minutes}-minute read"
  end
end
