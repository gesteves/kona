require "set"

# Puts the articles of the "Trending Articles" widget in order: the articles that people read more
# than their usual amount in approximately the last day or two. The code calculates this one time
# each clock hour from a moving Plausible window, and each viewer sees the same result. Thus the
# widget changes through the day, and it does not move as much as a "right now" signal would on a
# site with low traffic.
#
# The score of each article comes from Plausible queries that start at the current clock hour:
#   * heat          = the blended visitors in the last RECENT_WINDOW_HOURS. Refer to heat_by_path.
#   * baseline_rate = the blended visitors for each hour in the BASELINE_DAYS *before* the recent
#                     window, divided by the hours that the article existed. Thus a surge cannot
#                     make its own baseline larger.
#   * surge         = (heat + PRIOR) / (baseline_rate · RECENT_WINDOW_HOURS + PRIOR).
#   * score         = log(surge + 1) · relative_weight + log(heat + 1) · absolute_weight
#
# An article below the adaptive floor gets a score of 0 and goes into the group at the end, which
# the visitors of all time order. An article that is too new for a baseline gets its position from
# its volume.
class TrendingArticles < ApplicationService
  include ArticleRanking # candidates + payload, shared with RelatedArticles

  # The moving recent window, in hours. It is short, thus it means "today", and it is long, thus
  # it collects a signal that the code can use on a site with low traffic.
  RECENT_WINDOW_HOURS = Integer(ENV.fetch("TRENDING_RECENT_WINDOW_HOURS", 48))
  # The length of the baseline, in days. It ends where the recent window starts.
  BASELINE_DAYS = Integer(ENV.fetch("TRENDING_BASELINE_DAYS", 30))
  # The weight of a visitor who reached the article from inside the site. ⚠️ It must stay below 1.
  # This widget renders on the home page and on each Page, thus its own clicks are part of that
  # number, and a weight of 1 would let the widget order its own output. A weight of 0 counts the
  # demand from outside the site alone. Refer to heat_by_path.
  INTERNAL_WEIGHT = ENV.fetch("TRENDING_INTERNAL_WEIGHT", 0.5).to_f
  # ⚠️ The prior goes on BOTH sides of the surge ratio, on purpose. It moves a ratio from a small
  # count toward 1, which is "no surge". With the prior on the divisor alone, an article with no
  # baseline and 5 visitors got a surge of 5, and a true surge looked exactly the same.
  PRIOR = ENV.fetch("TRENDING_SURGE_PRIOR", 3).to_f
  # The code ignores an article below the floor, because its surge ratio has no meaning. The floor
  # is a percentile of the articles that got any traffic, and never less than this.
  ABSOLUTE_MIN = 2
  # The percentile of the floor, over the articles with traffic in the recent window.
  FLOOR_PERCENTILE = ENV.fetch("TRENDING_FLOOR_PERCENTILE", 0.5).to_f
  # The number of articles that must go past the floor. Below that number the floor drops to
  # ABSOLUTE_MIN. ⚠️ It is a constant and not the `count` of the caller, because the cache holds
  # one list for each hour and each caller shares it. A `count` here would make that list
  # different for each caller under one key.
  MIN_ABOVE_FLOOR = 4
  # The part of the list that the cache holds and the code serves. It keeps the cached JSON small
  # and the parse for each request short.
  MAX_POOL = 12
  # The cache key contains the hour, thus the list changes to a new one by itself.
  RESULT_TTL = 1.hour

  # @param articles [Articles] The source of the articles. A test can supply its own.
  # @param plausible [Plausible] The source of the analytics. A test can supply its own.
  def initialize(articles: Articles.new, plausible: Plausible.new)
    @articles = articles
    @plausible = plausible
  end

  # @return [Array<OpenStruct>] The first `count` hot articles.
  def all(count: 4)
    ranked.first(count)
  end

  private

  # Each thing that decides the content of the list, as a digest in the cache key.
  #
  # ⚠️ The settings are in here, on purpose. You can change them with an env var. With a version
  # number that a person writes, a change to a TRENDING_* var left the previous list in the cache
  # for its full hour, under a key that looked correct. The list was then old, and nothing showed
  # it.
  # @return [String]
  def ranking_version
    @ranking_version ||= cache_version(
      PAYLOAD_VERSION, RECENT_WINDOW_HOURS, BASELINE_DAYS, PRIOR, ABSOLUTE_MIN, FLOOR_PERCENTILE,
      MIN_ABOVE_FLOOR, MAX_POOL, INTERNAL_WEIGHT, relative_weight, absolute_weight
    )
  end

  # The full list in order, the hottest first. The code calculates it one time each clock hour,
  # and each variant uses it. On an error it is empty, which removes the widget and does not
  # raise.
  def ranked
    rescue_with([], context: self.class.name) do
      t_end = Time.current.utc.beginning_of_hour
      # ⚠️ An empty list means a failure, and it also means "nothing is trending". rank() costs
      # Plausible queries. Without the negative TTL, each request does all of them during a
      # Plausible failure. `(items || [])` below already accepts the nil from a blank cache.
      items = cached_json("trending:articles:ranked:#{ranking_version}:#{t_end.utc.iso8601}", expires_in: RESULT_TTL, empty_expires_in: 1.minute) do
        rank(t_end).map { |article| payload(article) }
      end
      (items || []).map { |item| DeepOstruct.wrap(item) }
    end
  end

  # Puts each candidate in order, the hottest first.
  # @param t_end [Time] The clock hour where the windows start.
  def rank(t_end)
    articles = candidates
    return [] if articles.blank?

    recent = heat_by_path(date_range: [ (t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601, t_end.iso8601 ])
    baseline = heat_by_path(date_range: [ (t_end - (BASELINE_DAYS * 86_400)).iso8601, (t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601 ])
    warn_if_no_analytics(articles, recent)

    baseline_end = t_end - (RECENT_WINDOW_HOURS * 3600)
    baseline_start = t_end - (BASELINE_DAYS * 86_400)
    floor = recent_floor(recent)
    popularity = all_time_visitors

    # ⚠️ The parse is in its own rescue for each article. One bad date made the full widget empty
    # for a full hour.
    evaluated = articles.filter_map do |article|
      published = published_at(article)
      next if published.nil?

      score, heat = evaluate(recent[article.path].to_f, baseline[article.path].to_f, published, baseline_start, baseline_end, floor)
      { article: article, score: score, heat: heat, popularity: popularity[article.path].to_i, published: published }
    end

    # ⚠️ The popularity of all time comes before the date. Thus the group with a score of 0 shows
    # the articles that people read the most, and the widget is not a copy of the list of new posts
    # on the home page. ⚠️ The date stays as the last key, because sort_by is not stable. Without
    # it, a corpus with no analytics gives a different order at each call.
    evaluated
      .sort_by { |e| [ -e[:score], -e[:heat], -e[:popularity], -e[:published].to_time.to_i ] }
      .first(MAX_POOL)
      .map { |e| e[:article] }
  end

  # The smallest number of recent visitors that gives a meaningful ratio. It comes from the
  # distribution of the site itself, thus no person tunes a number when the traffic changes.
  # @return [Integer]
  def recent_floor(recent)
    nonzero = recent.values.reject(&:zero?).sort
    return ABSOLUTE_MIN if nonzero.empty?

    floor = [ nonzero[(nonzero.size * FLOOR_PERCENTILE).floor].to_f, ABSOLUTE_MIN ].max
    # ⚠️ A quiet week must not empty the widget. Go back to the absolute minimum when too few
    # articles go past the percentile.
    return ABSOLUTE_MIN if nonzero.count { |value| value >= floor } < MIN_ABOVE_FLOOR

    floor
  end

  # The heat of each article over a date range: the visitors who arrived from outside the site, at
  # the full weight, plus the visitors who arrived from inside it, at INTERNAL_WEIGHT.
  #
  # ⚠️ The caller uses this for the recent window AND for the baseline. The two must use the same
  # blend, or the ratio between them has no meaning.
  #
  # ⚠️ A nil from either query means "not available", and this gives an empty hash for that. A
  # blend of one good query and one empty query would give a list that looks correct and is not:
  # with no entry visitors, each article would score on its internal traffic alone.
  # @param date_range [Array] A Plausible [from, to] pair.
  # @return [Hash] { path => heat }, with a default of 0.0.
  def heat_by_path(date_range:)
    entry = @plausible.entry_visitors_by_path(date_range: date_range)
    page = @plausible.page_visitors_by_path(date_range: date_range)
    return {} if entry.nil? || page.nil?

    (entry.keys | page.keys).each_with_object(Hash.new(0.0)) do |path, heat|
      external = entry[path].to_f
      # ⚠️ Clamp at zero. Plausible counts a visitor of an entry page in both numbers, thus the
      # difference is the internal arrivals. A small difference in the two queries must never make
      # this negative.
      internal = [ page[path].to_f - external, 0.0 ].max
      heat[path] = external + (INTERNAL_WEIGHT * internal)
    end
  end

  # ⚠️ The pageviews widget already caches this query body. Thus the fallback order costs no more
  # Plausible calls.
  # @return [Hash] { path => visitors of all time }.
  def all_time_visitors
    totals = @plausible.totals_by_path(date_range: "all") || {}
    totals.each_with_object(Hash.new(0)) { |(path, values), acc| acc[path] = values[:visitors].to_i }
  end

  # @return [DateTime, nil] The publish date, or nil when the code cannot parse it.
  def published_at(article)
    DateTime.parse(article.published_at)
  rescue Date::Error, TypeError
    Rails.logger.info("TrendingArticles: cannot parse the date of #{article.path.inspect}; the code omits it")
    nil
  end

  # Calculates the score of one article.
  # @return [Array(Float, Float)] Its [score, heat]. heat selects between two equal scores. Below
  #   the floor this is [0, 0], which goes into the group that the popularity orders.
  def evaluate(recent_visitors, baseline_total, published, baseline_start, baseline_end, floor)
    return [ 0.0, 0.0 ] if recent_visitors < floor

    volume = Math.log(recent_visitors + 1)

    # The hours that the article existed in the baseline window. Thus a new post does not get a
    # lower score for the days before its publication.
    existed_from = [ published.to_time, baseline_start ].max
    baseline_hours = (baseline_end - existed_from) / 3600.0

    score =
      if baseline_hours <= 0
        # The article is too new for a dependable baseline, thus the volume alone gives its
        # position. A burst at the start still appears, and the surge ratio is not infinite.
        volume * absolute_weight
      else
        baseline_rate = baseline_total / baseline_hours
        expected = baseline_rate * RECENT_WINDOW_HOURS
        surge = (recent_visitors + PRIOR) / (expected + PRIOR)
        Math.log(surge + 1) * relative_weight + volume * absolute_weight
      end

    [ score, recent_visitors.to_f ]
  end

  def relative_weight
    @relative_weight ||= ENV.fetch("TRENDING_SCORE_RELATIVE_WEIGHT", 1).to_f
  end

  # The defaults are less than 1. Thus the volume part stops a small change from a position above
  # a true surge, and the surge part has the most importance. The widget shows what is popular
  # now, and not what people read the most at any time.
  def absolute_weight
    @absolute_weight ||= ENV.fetch("TRENDING_SCORE_ABSOLUTE_WEIGHT", 0.5).to_f
  end

  # Writes a log line for the one condition that changes the list to popularity order with no
  # message: there are candidates but each one has zero recent visitors. That means that Plausible
  # is down or that the paths changed.
  def warn_if_no_analytics(articles, recent)
    return if articles.any? { |a| recent[a.path].to_f.positive? }
    Rails.logger.info("TrendingArticles: no visitors for any of #{articles.size} candidates over #{RECENT_WINDOW_HOURS}h (Plausible down or path mismatch?)")
  end
end
