# The entries that an entry page links to below its body: the other reports of the same race,
# the "You May Also Like" list, and the previous and the next entry.
module RecirculationHelpers
  # The entries for the two recirculation sections of an article: the reports of the same race, and
  # then the related entries.
  #
  # ⚠️ Do not make the two sections exclude each other: a race with few other reports then gives
  # one or two cards where four are possible. Keep the dedup below. A report of the same race is
  # often also a near entry by meaning, and the same card two times gives two equal DOM ids.
  # @param count [Integer] The number of cards in each section.
  # @return [Hash] { reports:, related: }. An empty list renders no section.
  def recirculation_sections(article, count: 4)
    reports = related_race_reports(article, count: count)

    seen = reports.filter_map { |a| a.sys&.id }.to_set
    related = related_section(article, count: count, seen: seen)

    { reports: reports, related: related }
  end

  # The entries of the "You May Also Like" section, without the entries that the page already
  # shows: the entry itself, the two adjacent entries of the read-next section, and each entry in
  # `seen`.
  #
  # ⚠️ An entry with a near meaning is frequently also the adjacent entry in time. Without this
  # removal the same card renders two times on the page. The api sends more neighbors than the
  # section shows (RelatedController::COUNT), thus the removal does not make the section short.
  # @param seen [Set<String>] The ids of the entries that another section already shows.
  # @return [Array<Object>]
  def related_section(article, count: 4, seen: Set.new)
    adjacent = adjacent_articles(article).values.compact
    removed = seen | adjacent.filter_map { |a| a.sys&.id }
    removed << article.sys&.id

    related_articles(article, count: count + removed.size)
      .reject { |a| removed.include?(a.sys&.id) }
      .take(count)
  end

  # The entries with the nearest meaning to this one, for the static "You May Also Like" section.
  # The order comes from data/related.json, which `rake import:related` gets from the api. The api
  # makes it from a BM25 index of the article text, from the links between the entries, and from
  # the concepts. It is the one part of the section that this build cannot make from its own data.
  #
  # ⚠️ An empty result removes the section. This is correct for the three causes of an empty
  # result: the import did not run (no api, or no token), the api could not read Contentful, or
  # each neighbor that it names is now unpublished.
  # @return [Array<Object>] The related entries, the nearest first.
  def related_articles(article, count: 4)
    return [] unless data.respond_to?(:related)

    ids = Array(data.related[article.sys&.id])
    return [] if ids.empty?

    index = published_articles_by_id
    ids.filter_map { |id| index[id] }.take(count)
  end

  # The adjacent entries in time, for the "Read next" navigation. It includes the Shorts, thus
  # the navigation works on both types of page.
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

  # The other race reports with the same race concept as this article, the newest first.
  # @return [Array<Object>]
  def related_race_reports(article, count: 4)
    race_id = race_concept_id(article)
    return [] if race_id.nil?

    Array(race_reports_by_race[race_id])
      .reject { |a| a.slug == article.slug }
      .take(count)
  end

  # Tells if an article has the race-report tag. Thus a race preview with the same race concept
  # cannot go into the group of race reports.
  def race_report?(article)
    Array(article.contentful_metadata&.tags).any? { |t| t.id == "race-reports" }
  end

  private

  # @return [Hash{String=>Object}] The published entries by Contentful id, to find the ids in
  #   data/related.json. The app keeps the value for the life of the collection, because it
  #   calls this one time for each article page.
  def published_articles_by_id
    memoize_by_collection(:published_articles_by_id, data.articles) do
      published_articles.index_by { |a| a.sys&.id }
    end
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

  # The id of the race concept of an article: its most deeply nested Sports concept at the race
  # level or below it (discipline › distance › race, thus the chain length is 3 or more). It
  # controls the groups of race reports.
  # @return [String, nil]
  def race_concept_id(article)
    Array(article.contentful_metadata&.tags)
      .select { |t| t.scheme == "sports" }
      .map { |t| [ t.id, concept_chain(t.id).length ] }
      .select { |_id, depth| depth >= 3 }
      .max_by { |_id, depth| depth }
      &.first
  end
end
