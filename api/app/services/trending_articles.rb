# Puts the articles of the "Trending Articles" widget in order: first each article that people
# read much more than its usual amount in the last days, and then the articles that people read
# the most in the last FILL_DAYS. The code calculates this one time each clock hour from one
# Plausible series of daily visitors, and each viewer sees the same result.
#
# The score of an article is a significance test and not a ratio, because the counts of this site
# are small. For each window of WINDOWS days:
#   * k        = the visitors in the window, with today as a partial day.
#   * rate     = (the visitors in the BASELINE_DAYS before the window + ALPHA) / (days + ALPHA).
#   * expected = rate · the days of the window.
#   * surprise = −log10 P(X ≥ k), where X is Poisson with the mean `expected`.
# The trend of the article is its largest surprise, and it is a trend when that is at least
# SIGNIFICANCE. ⚠️ ALPHA is a Gamma prior on the daily rate. It is what stops an article with a
# baseline of 0 from an infinite surprise. MIN_VISITORS is what stops two visitors from a trend.
#
# ⚠️ The RECENT_EXCLUDED newest Articles are never in the list. The home page lists them as
# "Recent Articles" directly above this widget, and the traffic of a new post is not a trend.
class TrendingArticles < ApplicationService
  include ArticleRanking # candidates + payload, shared with RelatedArticles

  # The windows, in days. A short one finds a spike of one day, and a long one finds a ramp.
  WINDOWS = ENV.fetch("TRENDING_WINDOWS", "2,7").split(",").map { |days| Integer(days.strip) }.freeze
  # The length of the baseline, in days. It ends where the window starts.
  BASELINE_DAYS = Integer(ENV.fetch("TRENDING_BASELINE_DAYS", 90))
  # An article with a shorter baseline cannot be a trend: its expected rate has no meaning.
  MIN_BASELINE_DAYS = 14
  # The visitors that a window needs before it can be a trend.
  MIN_VISITORS = Integer(ENV.fetch("TRENDING_MIN_VISITORS", 3))
  # The prior on the daily rate: one visitor on one day.
  ALPHA = 1.0
  # The surprise that makes a trend. 2.0 is a probability of 1 in 100.
  SIGNIFICANCE = ENV.fetch("TRENDING_SIGNIFICANCE", 2.0).to_f
  # The window of the fill: the articles below SIGNIFICANCE go in the order of their visitors in
  # these days.
  FILL_DAYS = Integer(ENV.fetch("TRENDING_FILL_DAYS", 30))
  # The newest Articles, which the list never holds.
  # ⚠️ This must stay equal to the `count: 4` of `recent_articles` in
  # web/lib/helpers/article_helpers.rb, and no check compares the two.
  RECENT_EXCLUDED = 4
  # The days of the series: the baseline and the longest window.
  SERIES_DAYS = BASELINE_DAYS + WINDOWS.max
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

  # @return [Array<OpenStruct>] The first `count` articles of the list.
  def all(count: 4)
    ranked.first(count)
  end

  # Each candidate with its numbers, in the order of the list, for `rake trending:*`. The ranking
  # calls this same method, thus the report can never describe a different list.
  # @param today [Date] The last day of the windows.
  # @param series [Hash, nil] A series from Plausible#daily_visitors_by_path that reaches `today`.
  #   With no value, the code gets one.
  # @return [Array<Hash>] { article:, status:, trend:, windows:, recent:, popularity: }. The
  #   status is :trend, :fill, or :recent, and the :recent rows are at the end.
  def evaluate(today: @plausible.site_today, series: nil)
    articles = candidates
    return [] if articles.blank?

    series ||= @plausible.daily_visitors_by_path(days: SERIES_DAYS, today: today)
    warn_if_no_analytics(articles, series)
    excluded = newest_ids(articles)
    popularity = all_time_visitors

    # ⚠️ The parse is in its own rescue for each article. One bad date made the full widget empty
    # for a full hour.
    rows = articles.filter_map do |article|
      published = published_on(article)
      next if published.nil?

      per_path = series&.fetch(article.path, nil) || {}
      windows = WINDOWS.to_h { |days| [ days, window_stats(per_path, published, today, days) ] }
      best = windows.values.select { |stats| stats[:surprise] }.max_by { |stats| [ stats[:surprise], stats[:visitors] ] }
      trend = best ? best[:surprise] : 0.0

      {
        article: article,
        status: status_of(article, trend, excluded, series),
        trend: trend,
        peak: best ? best[:visitors] : 0,
        windows: windows,
        recent: visitors_between(per_path, today - (FILL_DAYS - 1), today),
        popularity: popularity[article.path].to_i,
        published: published
      }
    end

    order(rows)
  end

  private

  # Each thing that decides the content of the list, as a digest in the cache key.
  #
  # ⚠️ The settings are in here, on purpose. You can change them with an env var. With a version
  # number that a person writes, a change to a TRENDING_* var left the previous list in the cache
  # for its full hour, under a key that looked correct.
  # @return [String]
  def ranking_version
    @ranking_version ||= cache_version(
      PAYLOAD_VERSION, WINDOWS.join(","), BASELINE_DAYS, MIN_BASELINE_DAYS, MIN_VISITORS, ALPHA,
      SIGNIFICANCE, FILL_DAYS, RECENT_EXCLUDED, MAX_POOL
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
        rank.map { |article| payload(article) }
      end
      (items || []).map { |item| DeepOstruct.wrap(item) }
    end
  end

  # @return [Array<OpenStruct>] The list, without the newest articles.
  def rank
    evaluate.reject { |row| row[:status] == :recent }.first(MAX_POOL).map { |row| row[:article] }
  end

  # The trends first, the largest surprise first. Then the others by the visitors of the last
  # FILL_DAYS, then the visitors of all time, then the date.
  #
  # ⚠️ The popularity of all time comes before the date. Thus with no analytics the list shows the
  # articles that people read the most, and the widget is not a copy of the list of new posts on
  # the home page. ⚠️ The date stays as the last key, because sort_by is not stable.
  def order(rows)
    rank_of = { trend: 0, fill: 1, recent: 2 }
    rows.sort_by do |row|
      trend = row[:status] == :trend
      [ rank_of[row[:status]], trend ? -row[:trend] : 0, trend ? -row[:peak] : 0, -row[:recent], -row[:popularity], -row[:published].jd ]
    end
  end

  def status_of(article, trend, excluded, series)
    return :recent if excluded.include?(article.sys&.id)
    return :fill if series.nil?

    trend >= SIGNIFICANCE ? :trend : :fill
  end

  # The numbers of one window: the visitors in it, the expected visitors from the baseline, and
  # the surprise. The last two are nil when the window cannot be a trend.
  # @return [Hash] { visitors:, expected:, surprise: }
  def window_stats(per_path, published, today, days)
    window_start = today - (days - 1)
    visitors = visitors_between(per_path, window_start, today)
    baseline_end = window_start - 1
    baseline_start = [ published, baseline_end - (BASELINE_DAYS - 1) ].max
    baseline_days = (baseline_end - baseline_start).to_i + 1
    return { visitors: visitors, expected: nil, surprise: nil } if baseline_days < MIN_BASELINE_DAYS || visitors < MIN_VISITORS

    rate = (visitors_between(per_path, baseline_start, baseline_end) + ALPHA) / (baseline_days + ALPHA)
    expected = rate * days

    { visitors: visitors, expected: expected, surprise: -Math.log10(poisson_tail(visitors, expected)) }
  end

  # P(X ≥ k) for a Poisson X with the mean `expected`.
  #
  # ⚠️ This sums the terms one after the other, and it never calls a factorial: 171! is larger
  # than a Float.
  # @return [Float] Never below 1e-15, thus the surprise is never infinite.
  def poisson_tail(k, expected)
    term = Math.exp(-expected)
    sum = 0.0
    k.to_i.times do |i|
      sum += term
      term *= expected / (i + 1)
    end

    [ 1.0 - sum, 1e-15 ].max
  end

  # @return [Integer] The visitors from `from` to `to`, both inclusive.
  def visitors_between(per_path, from, to)
    per_path.sum { |day, visitors| from <= day && day <= to ? visitors.to_i : 0 }
  end

  # @return [Set<String>] The ids of the RECENT_EXCLUDED newest articles.
  def newest_ids(articles)
    articles.sort_by { |a| -(published_on(a) || Date.new(1970)).jd }.first(RECENT_EXCLUDED).filter_map { |a| a.sys&.id }.to_set
  end

  # ⚠️ The pageviews widget already caches this query body. Thus the fallback order costs no more
  # Plausible calls.
  # @return [Hash] { path => visitors of all time }.
  def all_time_visitors
    totals = @plausible.totals_by_path(date_range: "all") || {}
    totals.each_with_object(Hash.new(0)) { |(path, values), acc| acc[path] = values[:visitors].to_i }
  end

  # @return [Date, nil] The publish day in the zone of the site, or nil when the code cannot
  #   parse it.
  def published_on(article)
    DateTime.parse(article.published_at).in_time_zone(TimeZoneResolver.default).to_date
  rescue Date::Error, TypeError
    Rails.logger.info("TrendingArticles: cannot parse the date of #{article.path.inspect}; the code omits it")
    nil
  end

  # Writes a log line for the one condition that changes the list to popularity order with no
  # message: there are candidates but the series holds no visitor for any of them. That means that
  # Plausible is down or that the paths changed.
  def warn_if_no_analytics(articles, series)
    return if series.nil? || articles.any? { |a| series[a.path].present? }
    Rails.logger.info("TrendingArticles: no visitors for any of #{articles.size} candidates over #{SERIES_DAYS} days (Plausible down or path mismatch?)")
  end
end
