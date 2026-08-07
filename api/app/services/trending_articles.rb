require "set"

# Ranks the "Trending Articles" widget: which articles are being read more than their own
# normal over roughly the last day or two. Recomputed once per clock hour off a rolling
# Plausible window and shared by every viewer, so the widget moves through the day without the
# jumpiness a "right now" signal would have on a low-traffic site.
#
# Scoring, per article, from two Plausible queries anchored on the current clock hour:
#   * heat          = pageviews over the last RECENT_WINDOW_HOURS, counted flat.
#   * baseline_rate = pageviews/hour over the BASELINE_DAYS *before* the recent window, so a
#                     surge can't inflate its own baseline, spread over the hours it existed.
#   * surge         = heat / (baseline_rate · RECENT_WINDOW_HOURS + SMOOTHING).
#   * score         = log(surge + 1) · relative_weight + log(heat + 1) · absolute_weight
#
# Articles below MIN_RECENT_PAGEVIEWS score 0 and fall into the recency tail; articles too new
# to have a baseline rank on volume alone.
class TrendingArticles < ApplicationService
  include ArticleRanking # candidates + payload, shared with RelatedArticles

  # The rolling recent window, in hours: short enough to read as "today", long enough to
  # accumulate a usable signal on a low-traffic site.
  RECENT_WINDOW_HOURS = Integer(ENV.fetch("TRENDING_RECENT_WINDOW_HOURS", 48))
  # How far back the baseline reaches, in days, ending where the recent window begins.
  BASELINE_DAYS = Integer(ENV.fetch("TRENDING_BASELINE_DAYS", 30))
  # Articles below this much recent traffic are ignored — their surge ratios are pure noise.
  MIN_RECENT_PAGEVIEWS = 5
  # Smooths the surge denominator, so a near-zero baseline can't explode the ratio.
  SMOOTHING = 1.0
  # How much of the ranking to cache and serve. A caller excludes at most the handful of cards
  # it shows, so this always fills `count` after exclusions while bounding the cached JSON and
  # the per-request deserializing.
  MAX_POOL = 50
  # The cache key carries the hour bucket, so the ranking rolls over on its own.
  RESULT_TTL = 1.hour

  # @param articles [Articles] The corpus source; injectable for testing.
  # @param plausible [Plausible] The analytics source; injectable for testing.
  def initialize(articles: Articles.new, plausible: Plausible.new)
    @articles = articles
    @plausible = plausible
  end

  # @return [Array<OpenStruct>] The top `count` hot articles.
  def all(count: 4)
    ranked.first(count)
  end

  # The top `count` hot articles, minus any whose Contentful id is in `ids`, so a page can drop
  # the cards it already shows — an article page drops itself.
  # @return [Array<OpenStruct>]
  def excluding(ids, count: 4)
    excluded = Array(ids).to_set
    ranked.reject { |article| excluded.include?(article.sys&.id) }.first(count)
  end

  private

  # Everything that determines the ranking's contents, digested into the cache key.
  #
  # ⚠️ The tuning knobs are in here deliberately. They're env-tunable, and with a hand-written
  # version alone, retuning one of the TRENDING_* vars left the previous ranking cached for its
  # full hour under a key that looked current — a stale ranking with no way to tell.
  # @return [String]
  def ranking_version
    @ranking_version ||= cache_version(
      PAYLOAD_VERSION, RECENT_WINDOW_HOURS, BASELINE_DAYS, MIN_RECENT_PAGEVIEWS,
      SMOOTHING, MAX_POOL, relative_weight, absolute_weight
    )
  end

  # The full ranked list, hottest first, computed once per clock hour and shared by every
  # variant. Empty on any error, which collapses the widget rather than raising.
  def ranked
    rescue_with([], context: self.class.name) do
      t_end = Time.now.beginning_of_hour
      items = cached_json("trending:articles:ranked:#{ranking_version}:#{t_end.utc.iso8601}", expires_in: RESULT_TTL) do
        rank(t_end).map { |article| payload(article) }
      end
      (items || []).map { |item| DeepOstruct.wrap(item) }
    end
  end

  # Ranks every candidate, hottest first.
  # @param t_end [Time] The clock hour the windows are anchored on.
  def rank(t_end)
    articles = candidates
    return [] if articles.blank?

    recent = pageviews_by_path(date_range: [(t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601, t_end.iso8601])
    baseline = pageviews_by_path(date_range: [(t_end - (BASELINE_DAYS * 86_400)).iso8601, (t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601])
    warn_if_no_analytics(articles, recent)

    baseline_end = t_end - (RECENT_WINDOW_HOURS * 3600)
    baseline_start = t_end - (BASELINE_DAYS * 86_400)
    # Parsed once per article; also the only thing here that can raise.
    published = articles.to_h { |article| [article.path, DateTime.parse(article.published_at)] }

    evaluated = articles.map do |article|
      score, heat = evaluate(recent[article.path].to_i, baseline[article.path].to_f, published[article.path], baseline_start, baseline_end)
      { article: article, score: score, heat: heat, published: published[article.path] }
    end

    # Recency is the last sort key so the zero-scored tail runs newest-first, which is what
    # fills the widget with recent articles when little or nothing is hot.
    evaluated
      .sort_by { |e| [-e[:score], -e[:heat], -e[:published].to_time.to_i] }
      .first(MAX_POOL)
      .map { |e| e[:article] }
  end

  # One Plausible call for a date range. An unavailable query degrades to an empty hash, which
  # scores every article zero and falls the ranking back to recency order.
  # @return [Hash] { path => total_pageviews }.
  def pageviews_by_path(date_range:)
    @plausible.pageviews_by_path(date_range: date_range) || {}
  end

  # Scores one article.
  # @return [Array(Float, Float)] Its [score, heat]; heat is the tiebreaker. Below the recent
  #   traffic floor this is [0, 0], which sorts into the recency tail.
  def evaluate(recent_pageviews, baseline_total, published, baseline_start, baseline_end)
    return [0.0, 0.0] if recent_pageviews < MIN_RECENT_PAGEVIEWS

    volume = Math.log(recent_pageviews + 1)

    # Hours the article existed within the baseline window, so a young post isn't penalized for
    # the days before it was published.
    existed_from = [published.to_time, baseline_start].max
    baseline_hours = (baseline_end - existed_from) / 3600.0

    score =
      if baseline_hours <= 0
        # Too new for a trustworthy baseline, so rank on volume alone — a launch burst still
        # surfaces, without an infinite surge ratio.
        volume * absolute_weight
      else
        baseline_rate = baseline_total / baseline_hours
        expected = baseline_rate * RECENT_WINDOW_HOURS
        surge = recent_pageviews / (expected + SMOOTHING)
        Math.log(surge + 1) * relative_weight + volume * absolute_weight
      end

    [score, recent_pageviews.to_f]
  end

  def relative_weight
    @relative_weight ||= ENV.fetch("TRENDING_SCORE_RELATIVE_WEIGHT", 1).to_f
  end

  # Defaults below 1, so the volume term stays a guard against a small blip outranking a real
  # surge while the surge term leads. The widget is "having a moment", not "most-read ever".
  def absolute_weight
    @absolute_weight ||= ENV.fetch("TRENDING_SCORE_ABSOLUTE_WEIGHT", 0.5).to_f
  end

  # Logs the one case that silently collapses trending to recency order: candidates present but
  # zero recent pageviews across all of them, meaning Plausible is down or paths have drifted.
  def warn_if_no_analytics(articles, recent)
    return if articles.any? { |a| recent[a.path].to_i.positive? }
    Rails.logger.info("TrendingArticles: no recent pageviews for any of #{articles.size} candidates over #{RECENT_WINDOW_HOURS}h (Plausible down or path mismatch?)")
  end
end
