require 'text'

module ArticleHelpers
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
    options = {
      href: article.path,
      title: "Published at #{DateTime.parse(article.published_at).strftime('%-I:%M %p')}",
      "data-publish-date-target": "timestamp"
    }
    content_tag :a, options do
      DateTime.parse(article.published_at).strftime('%A, %B %-e, %Y')
    end
  end

  # Determines whether the content should be hidden from search engines.
  # @return [Boolean] Returns true if the page should be hidden from search engines.
  def hide_from_search_engines?
    return true unless is_production?
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
    data.articles
      .reject { |a| a.path == exclude&.path } # Exclude the given article, if applicable
      .reject { |a| a.draft }                 # Exclude drafts
      .reject { |a| a.entry_type == 'Short' } # Exclude short posts
      .take(count)
  end

  # Retrieves a specified number of the most recent articles for the RSS feed, excluding drafts.
  # @param count [Integer] (Optional) The number of recent articles to return. Default is 100.
  # @return [Array<Object>] An array of the most recent articles, up to the specified count.
  def feed_articles(count: 100)
    data.articles.reject { |a| a.draft }.take(count)
  end

  # Retrieves the articles to list in llms.txt: full articles only (no shorts), indexable, and
  # newest first (data.articles is already sorted by publish date, descending).
  # @param count [Integer] (Optional) The maximum number of articles to return. Default is 100.
  # @return [Array<Object>] An array of the most recent indexable full articles.
  def llms_articles(count: 100)
    data.articles
      .reject { |a| a.draft || !a.index_in_search_engines }
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
    sequence = data.articles.reject { |a| a.draft }
    index = sequence.index { |a| a.path == article.path }
    return { newer: nil, older: nil } if index.nil?

    { newer: index.positive? ? sequence[index - 1] : nil, older: sequence[index + 1] }
  end

  # Short, common words that carry no topical signal — dropped before comparing titles so two
  # titles don't look similar just because they both contain "the", "my", "a race", etc.
  TITLE_STOPWORDS = %w[a an and as at but by for from in into of on or the to with my your our this that].freeze

  # Returns the articles most relevant to the given article, most relevant first.
  # Ranked purely on topical similarity (shared tags + title), with recency as a tiebreaker so the
  # most genuinely-related posts win regardless of age and near-ties favor the newer post.
  # @param article [Object] The reference article for finding related articles.
  # @param count [Integer] (Optional) The number of articles to return.
  # @return [Array<Object>] A list of articles sorted by relevance.
  def related_articles(article, count: 4)
    # The article page asks for this twice per render (the "You May Also Like" section and the
    # trending widget's exclusion set), so memoize the similarity computation within the page render.
    @related_articles_memo ||= {}
    return @related_articles_memo[[article.path, count]] if @related_articles_memo.key?([article.path, count])

    # Get race reports that will be shown in the race reports section
    race_report_slugs = related_race_reports(article).map(&:slug)

    # The reference article's tags and normalized title are constant across every comparison,
    # so compute them (and the weights) once here instead of per-candidate inside the sort.
    ref_tags = tag_ids(article)
    ref_title = normalize_title(article.title)
    tags_weight = ENV.fetch('SIMILARITY_SCORE_TAGS_WEIGHT', 1).to_f
    title_weight = ENV.fetch('SIMILARITY_SCORE_TITLE_WEIGHT', 1).to_f

    @related_articles_memo[[article.path, count]] = data.articles
      .reject { |a| a.path == article.path }             # Exclude the current article
      .reject { |a| a.draft }                            # Exclude drafts
      .reject { |a| a.entry_type == 'Short' }            # Exclude short posts
      .reject { |a| race_report_slugs.include?(a.slug) } # Exclude race reports shown in race reports section
      # Sort by topical similarity (desc), breaking ties toward the more recently published article.
      .sort_by { |a| [-similarity_against(a, ref_tags, ref_title, tags_weight, title_weight), -DateTime.parse(a.published_at).to_i] }
      .take(count)
  end

  # Calculates an overall topical-similarity score between two articles, considering:
  # - Shared tags, weighted by rarity (a shared niche tag means far more than a shared broad one) and
  #   normalized as a symmetric weighted Jaccard, so a heavily-tagged "about everything" post can't
  #   score a perfect match against everything.
  # - Title similarity (a secondary signal), after stripping stopwords so shared filler words don't
  #   inflate it.
  # @param article [Object] The reference article.
  # @param candidate [Object] The article to evaluate for similarity.
  # @return [Float] The similarity score.
  def similarity_score(article, candidate)
    tags_weight = ENV.fetch('SIMILARITY_SCORE_TAGS_WEIGHT', 1).to_f
    title_weight = ENV.fetch('SIMILARITY_SCORE_TITLE_WEIGHT', 1).to_f
    similarity_against(candidate, tag_ids(article), normalize_title(article.title), tags_weight, title_weight)
  end

  # Scores a candidate against an already-resolved reference article (its tag ids and normalized
  # title), so callers ranking many candidates against one article don't recompute the reference
  # side every comparison. See {#similarity_score} for the scoring rationale.
  # @return [Float] The similarity score.
  def similarity_against(candidate, ref_tags, ref_title, tags_weight, title_weight)
    # Tags score: IDF-weighted Jaccard. Each tag contributes its inverse-document-frequency weight,
    # so rare shared tags dominate and ubiquitous ones barely register; symmetric over the union.
    cand = tag_ids(candidate)
    shared = ref_tags & cand
    union = ref_tags | cand
    tags_score = union.empty? ? 0.0 : shared.sum { |id| tag_idf[id] } / union.sum { |id| tag_idf[id] }

    # Title score uses Text::WhiteSimilarity over the normalized (stopword-stripped) titles.
    title_score = white_similarity.similarity(ref_title, normalize_title(candidate.title))

    (tags_score * tags_weight) + (title_score * title_weight)
  end

  # The inverse-document-frequency weight of every tag, over the same universe related_articles ranks
  # (published, non-draft, non-Short articles). A tag on every article weighs ~nothing; a rare one
  # weighs a lot. Unseen tags default to the maximum (maximally-rare) weight. Memoized per render.
  # @return [Hash{String=>Float}] tag id => idf weight (defaults to the max weight for unknown tags).
  def tag_idf
    ArticleHelpers.tag_idf(data.articles)
  end

  # Computes the per-tag IDF weights once per build rather than once per article-page render
  # (Middleman builds a fresh template context per page, so the instance-level memo never
  # persisted across pages — this was O(corpus) repeated for every article). Memoized at the
  # module level, keyed on the corpus array's identity: in a build `data.articles` returns the
  # same object across renders → one computation; each spec example stubs a distinct array → no
  # result bleed even when two corpora happen to be the same size.
  # @param articles [Array<Object>] The full article corpus (`data.articles`).
  # @return [Hash{String=>Float}] tag id => idf weight (defaults to the max weight for unknown tags).
  def self.tag_idf(articles)
    return @tag_idf if defined?(@tag_idf_articles) && @tag_idf_articles.equal?(articles)

    @tag_idf_articles = articles
    corpus = articles.reject { |a| a.draft || a.entry_type == 'Short' }
    n = corpus.size
    document_frequency = Hash.new(0)
    corpus.each { |a| Array(a.contentful_metadata&.tags).map(&:id).each { |id| document_frequency[id] += 1 } }
    idf = Hash.new(Math.log((n + 1.0) / 1) + 1) # default: an unseen tag is treated as maximally rare
    document_frequency.each { |id, count| idf[id] = Math.log((n + 1.0) / (count + 1)) + 1 } # smoothed
    @tag_idf = idf
  end

  # The tag ids on an article (empty array when it has none).
  # @return [Array<String>]
  def tag_ids(article)
    Array(article.contentful_metadata&.tags).map(&:id)
  end

  # Strips an article title down to its meaningful words for comparison: plain text, lowercased,
  # punctuation removed, stopwords dropped.
  # @return [String]
  def normalize_title(title)
    sanitize(title).to_s.downcase.gsub(/[^a-z0-9\s]/, ' ').split(/\s+/).reject { |w| TITLE_STOPWORDS.include?(w) }.join(' ')
  end

  # A single reused WhiteSimilarity instance (it's stateless; no need to allocate one per comparison).
  def white_similarity
    @white_similarity ||= Text::WhiteSimilarity.new
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
      "datePublished": DateTime.parse(content.published_at).iso8601,
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
      schema["keywords"] = tags.map(&:name)
      schema["articleSection"] = tags.first.name
    end
    if content&.cover_image&.url.present?
      schema["image"] = ["1000x1000", "1600x900", "1600x1200"].map do |s|
        w, h = s.split('x').map(&:to_i)
        {
          "@type": "ImageObject",
          "url": cdn_image_url(content.cover_image.url, { w: w, h: h, fit: 'cover' }),
          "width": w,
          "height": h
        }
      end
    end
    schema.to_json
  end

  # Generates a JSON-LD schema string for breadcrumb navigation, based on the provided content.
  # @param content [Object] An object containing the article's data.
  # @see https://developers.google.com/search/docs/appearance/structured-data/breadcrumb
  # @return [String] A JSON-LD formatted string representing the breadcrumb schema.
  def breadcrumb_schema(content)
    return if content.draft || content.entry_type != 'Article'
    
    schema = {
      "@context": "https://schema.org",
      "@type": "BreadcrumbList",
      "itemListElement": [
        {
          "@type": "ListItem",
          "position": 1,
          "name": "Home",
          "item": full_url('/')
        },
        {
          "@type": "ListItem",
          "position": 2,
          "name": "Blog",
          "item": full_url('/blog')
        },
        {
          "@type": "ListItem",
          "position": 3,
          "name": sanitize(content.title),
          "item": canonical_url
        }
      ]
    }
    
    schema.to_json
  end

  # Counts the words in an article's prose (intro + body, as plain text). Shared by the reading-time
  # estimate and the BlogPosting schema's wordCount.
  # @param article [Object] The article.
  # @return [Integer] The number of words.
  def article_word_count(article)
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
    article = minutes.humanize.match?(/^(eight|eleven|eighteen)/i) ? 'An' : 'A'
    "#{article} #{minutes}-minute read"
  end

  # Finds related race reports from the same event as the current article.
  # @param article [Object] The current article to find race reports for.
  # @param count [Integer] (Optional) The number of race reports to return.
  # @return [Array<Object>] A list of race reports from the same event, sorted by publication date in reverse chronological order.
  def related_race_reports(article, count: 5)
    return [] unless article.event&.sys&.id

    # Find all articles that are linked to the same event
    race_reports = data.articles
      .select { |a| a.event&.sys&.id == article.event.sys.id }
      .reject { |a| a.slug == article.slug }
      .reject { |a| a.draft }
      .reject { |a| a.entry_type == 'Short' }
      .sort_by { |a| -DateTime.parse(a.published_at).to_i }
      .take(count)

    race_reports
  end
end
