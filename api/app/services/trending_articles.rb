require "set"

# Puts the articles of the "Trending Articles" widget in order: the articles that people read
# more than their usual amount in approximately the last day or two. The code calculates this one
# time each clock hour from a moving Plausible window, and each viewer sees the same result. Thus
# the widget changes through the day, and it does not move as much as a "right now" signal would
# on a site with low traffic.
#
# The score of each article comes from two Plausible queries that start at the current clock hour:
#   * heat          = the pageviews in the last RECENT_WINDOW_HOURS, with no weight.
#   * baseline_rate = the pageviews for each hour in the BASELINE_DAYS *before* the recent window,
#                     divided by the hours that the article existed. Thus a surge cannot make its
#                     own baseline larger.
#   * surge         = heat / (baseline_rate · RECENT_WINDOW_HOURS + SMOOTHING).
#   * score         = log(surge + 1) · relative_weight + log(heat + 1) · absolute_weight
#
# An article below MIN_RECENT_PAGEVIEWS gets a score of 0 and goes into the group at the end that
# the date orders. An article that is too new for a baseline gets its position from its volume.
class TrendingArticles < ApplicationService
  include ArticleRanking # candidates + payload, shared with RelatedArticles

  # The moving recent window, in hours. It is short, thus it means "today", and it is long, thus
  # it collects a signal that the code can use on a site with low traffic.
  RECENT_WINDOW_HOURS = Integer(ENV.fetch("TRENDING_RECENT_WINDOW_HOURS", 48))
  # The length of the baseline, in days. It ends where the recent window starts.
  BASELINE_DAYS = Integer(ENV.fetch("TRENDING_BASELINE_DAYS", 30))
  # The code ignores an article with less recent traffic than this, because its surge ratio has
  # no meaning.
  MIN_RECENT_PAGEVIEWS = 5
  # Increases the divisor of the surge, thus a baseline near zero cannot make the ratio very
  # large.
  SMOOTHING = 1.0
  # The part of the list that the cache holds and the code serves. A caller removes only the few
  # cards that it shows. Thus this always gives `count` articles after those removals, and it
  # keeps the cached JSON small and the parse for each request short.
  MAX_POOL = 50
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
      PAYLOAD_VERSION, RECENT_WINDOW_HOURS, BASELINE_DAYS, MIN_RECENT_PAGEVIEWS,
      SMOOTHING, MAX_POOL, relative_weight, absolute_weight
    )
  end

  # The full list in order, the hottest first. The code calculates it one time each clock hour,
  # and each variant uses it. On an error it is empty, which removes the widget and does not
  # raise.
  def ranked
    rescue_with([], context: self.class.name) do
      t_end = Time.now.beginning_of_hour
      # ⚠️ An empty list means a failure, and it also means "nothing is trending". rank() costs
      # two Plausible queries. Without the negative TTL, each request does both of them during a
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

    recent = pageviews_by_path(date_range: [ (t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601, t_end.iso8601 ])
    baseline = pageviews_by_path(date_range: [ (t_end - (BASELINE_DAYS * 86_400)).iso8601, (t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601 ])
    warn_if_no_analytics(articles, recent)

    baseline_end = t_end - (RECENT_WINDOW_HOURS * 3600)
    baseline_start = t_end - (BASELINE_DAYS * 86_400)
    # The code parses one time for each article. This is also the only code here that can raise.
    published = articles.to_h { |article| [ article.path, DateTime.parse(article.published_at) ] }

    evaluated = articles.map do |article|
      score, heat = evaluate(recent[article.path].to_i, baseline[article.path].to_f, published[article.path], baseline_start, baseline_end)
      { article: article, score: score, heat: heat, published: published[article.path] }
    end

    # The date is the last sort key, thus the group with a score of 0 has the newest article
    # first. That is what puts recent articles in the widget when few articles are hot.
    evaluated
      .sort_by { |e| [ -e[:score], -e[:heat], -e[:published].to_time.to_i ] }
      .first(MAX_POOL)
      .map { |e| e[:article] }
  end

  # One Plausible call for a date range. A query that is not available gives an empty hash, which
  # gives each article a score of 0 and puts the list in date order.
  # @return [Hash] { path => total_pageviews }.
  def pageviews_by_path(date_range:)
    @plausible.pageviews_by_path(date_range: date_range) || {}
  end

  # Calculates the score of one article.
  # @return [Array(Float, Float)] Its [score, heat]. heat selects between two equal scores. Below
  #   the recent-traffic minimum this is [0, 0], which goes into the group that the date orders.
  def evaluate(recent_pageviews, baseline_total, published, baseline_start, baseline_end)
    return [ 0.0, 0.0 ] if recent_pageviews < MIN_RECENT_PAGEVIEWS

    volume = Math.log(recent_pageviews + 1)

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
        surge = recent_pageviews / (expected + SMOOTHING)
        Math.log(surge + 1) * relative_weight + volume * absolute_weight
      end

    [ score, recent_pageviews.to_f ]
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

  # Writes a log line for the one condition that changes the list to date order with no message:
  # there are candidates but each one has zero recent pageviews. That means that Plausible is down
  # or that the paths changed.
  def warn_if_no_analytics(articles, recent)
    return if articles.any? { |a| recent[a.path].to_i.positive? }
    Rails.logger.info("TrendingArticles: no recent pageviews for any of #{articles.size} candidates over #{RECENT_WINDOW_HOURS}h (Plausible down or path mismatch?)")
  end
end
