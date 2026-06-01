require "set"

# Ranks the home page's "Trending Articles" at request time from Plausible analytics, replacing the
# build-time bake. Loads the published article corpus (Articles#list) plus a per-article daily
# pageview series, scores each article by how much its recent traffic is spiking *relative to its own
# normal volume*, and returns the non-recent trending set.
#
# Scoring (per article), all derived from one daily time series over WINDOW_DAYS:
#   * recent_rate = mean pageviews over the last RECENT_DAYS — a single day is too noisy to trust.
#   * baseline    = the days before that (and after the article was published, so pre-publish zeros
#                   don't masquerade as "low traffic"); gives mean μ and sample variance σ².
#   * spike z     = (recent_rate − μ) / sqrt(σ² + μ + 1) — a significance-aware score (Poisson-floored
#                   and smoothed) so a 1→5 blip on a near-dead post can't outrank a real surge on a
#                   busy one, and no window being zero is fatal.
#   * volume      = log(recent_rate + 1) — a genuine absolute-popularity term, so "lots of people are
#                   reading this right now" counts, not just the ratio.
#   * score       = z · relative_weight + volume · absolute_weight
# Articles with too little history or traffic skip the spike term (volume only) or are scored 0, so
# launch bursts and statistical noise don't trend.
class TrendingArticles < ApplicationService
  # One Plausible query returns a per-article daily pageview series over this window — no separate
  # 1d/7d/all calls. 30 days gives a stable per-article baseline while staying within one request.
  WINDOW_DAYS = 30
  # The current-momentum window: average the last few days instead of trusting a single noisy day.
  RECENT_DAYS = 3
  # Days of pre-recent, post-publish history an article needs before its baseline mean/σ is
  # trustworthy. Younger or sparser articles rank on volume alone, so a fresh post's launch burst
  # can't masquerade as a spike (the most-recent posts are dropped from this widget anyway).
  MIN_BASELINE_DAYS = 7
  # Ignore articles with essentially no traffic over the window — their ratios are pure noise.
  MIN_WINDOW_PAGEVIEWS = 10
  # Only article pages (paths like /2026/05/24/slug/), matching web's process_analytics filter.
  ARTICLE_PATH_FILTER = [["matches", "event:page", ["^/20\\d{2}/"]]].freeze
  # Consider this many top-trending articles before dropping the most-recent ones.
  CANDIDATE_MULTIPLIER = 2
  # The ranking is identical for every viewer and changes slowly, so memoize it briefly.
  RESULT_TTL = 10.minutes

  # @param articles [Articles] corpus source (injectable for testing)
  # @param plausible [Plausible] analytics source (injectable for testing)
  def initialize(articles: Articles.new, plausible: Plausible.new)
    @articles = articles
    @plausible = plausible
  end

  # The home page's trending set: the top trending articles, minus the N most recent, capped at N.
  # Cached briefly, and degrades to an empty list (→ render_empty) on any error rather than raising.
  # @return [Array<OpenStruct>]
  def non_recent(count: 4)
    rescue_with([], context: self.class.name) do
      items = cached_json("trending:articles:non_recent:v2:count:#{count}", expires_in: RESULT_TTL) do
        rank(count).map { |article| payload(article) }
      end
      (items || []).map { |item| DeepOstruct.wrap(item) }
    end
  end

  private

  # Computes the ranked, non-recent trending articles (returns the corpus DeepOstructs).
  def rank(count)
    articles = candidates
    return [] if articles.blank?

    axis, series = daily_series
    warn_if_no_analytics(articles, series)

    # Parse each publish date exactly once (it's also the only thing here that can raise).
    published = articles.to_h { |article| [article.path, DateTime.parse(article.published_at)] }

    evaluated = articles.map do |article|
      score, recent = evaluate(series[article.path], axis, published[article.path])
      { article: article, score: score, recent: recent, published: published[article.path] }
    end

    # Sort by spike score, then recent volume, then recency — the last key makes the no-analytics
    # fallback deterministic (newest first) instead of relying on stable sort.
    trending = evaluated
      .sort_by { |e| [-e[:score], -e[:recent], -e[:published].to_time.to_i] }
      .map { |e| e[:article] }
      .take(count * CANDIDATE_MULTIPLIER)

    recent_paths = Set.new(articles.max_by(count) { |a| published[a.path] }.map(&:path))
    trending.reject { |a| recent_paths.include?(a.path) }.take(count)
  end

  # Published, non-Short articles with a resolvable path (drafts/Shorts excluded — matches web).
  def candidates
    @articles.list.reject { |a| a.draft || a.entry_type == "Short" || a.path.blank? }
  end

  # One Plausible call → [axis, { path => [pv_day0, …, pv_dayN] }] where the array is the daily
  # pageviews aligned to `axis` (ascending dates, last = today), zero-filled for missing days.
  def daily_series
    rows = @plausible.query(
      metrics: ["pageviews"],
      date_range: "#{WINDOW_DAYS}d",
      dimensions: ["event:page", "time:day"],
      filters: ARTICLE_PATH_FILTER
    )&.dig(:results) || []

    by_path = Hash.new { |hash, key| hash[key] = {} }
    labels = []
    rows.each do |row|
      path = normalize_path(row[:dimensions]&.first)
      day = row[:dimensions] && row[:dimensions][1]
      next if path.blank? || day.blank?
      by_path[path][day] = row[:metrics]&.first.to_i
      labels << day
    end

    axis = day_axis(labels)
    series = by_path.transform_values { |day_pv| axis.map { |date| day_pv[date.iso8601].to_i } }
    [axis, series]
  end

  # The ascending date axis. Anchored on the latest day Plausible actually returned (robust to any
  # site/server timezone drift), falling back to today when there's no data.
  def day_axis(labels)
    anchor = labels.map { |label| Date.parse(label) }.max || Date.current
    Array.new(WINDOW_DAYS) { |i| anchor - (WINDOW_DAYS - 1 - i) }
  end

  # Scores one article's daily series. Returns [score, recent_pageviews] (the latter is a tiebreaker).
  def evaluate(series, axis, published)
    return [0.0, 0] if series.blank?

    # Only days on/after the article was published — pre-publish days are "didn't exist", not "quiet".
    pub_date = published.to_date
    vals = axis.each_index.select { |i| axis[i] >= pub_date }.map { |i| series[i] }
    return [0.0, 0] if vals.sum < MIN_WINDOW_PAGEVIEWS

    recent = vals.last(RECENT_DAYS)
    baseline = vals.first([vals.size - recent.size, 0].max)
    recent_rate = mean(recent)
    volume = Math.log(recent_rate + 1)

    score =
      if baseline.size >= MIN_BASELINE_DAYS
        mu = mean(baseline)
        # sqrt(σ² + μ + 1): sample variance blended with a Poisson prior and a +1 smoother, so the
        # denominator scales with volume and is never zero. High-traffic posts need a bigger jump for
        # the same z; low-traffic noise is damped.
        denom = Math.sqrt(variance(baseline, mu) + mu + 1)
        z = (recent_rate - mu) / denom
        z * relative_weight + volume * absolute_weight
      else
        # Not enough history for a trustworthy baseline → rank on raw recent volume alone.
        volume * absolute_weight
      end

    [score, recent.sum]
  end

  def mean(values)
    return 0.0 if values.empty?
    values.sum.to_f / values.size
  end

  # Sample variance (Bessel-corrected); 0 for fewer than two points.
  def variance(values, mu)
    return 0.0 if values.size < 2
    values.sum { |v| (v - mu)**2 }.to_f / (values.size - 1)
  end

  def relative_weight
    @relative_weight ||= ENV.fetch("TRENDING_SCORE_RELATIVE_WEIGHT", 1).to_f
  end

  def absolute_weight
    @absolute_weight ||= ENV.fetch("TRENDING_SCORE_ABSOLUTE_WEIGHT", 1).to_f
  end

  # Plausible reports clean URLs already, but normalize any trailing index.html to match paths.
  def normalize_path(path)
    return if path.blank?
    path.to_s.sub(/index\.html\z/, "")
  end

  # The fields the trending-card view renders, so the cached ranking is self-contained.
  def payload(article)
    {
      title: article.title,
      summary: article.summary,
      slug: article.slug,
      path: article.path,
      published_at: article.published_at,
      entry_type: article.entry_type,
      draft: article.draft,
      sys: { id: article.sys&.id }
    }
  end

  # Cheap signal for "analytics unavailable or a path-format regression": with candidates present but
  # zero pageviews for all of them, trending silently collapses to recency order.
  def warn_if_no_analytics(articles, series)
    return if articles.any? { |a| (series[a.path] || []).sum.positive? }
    Rails.logger.info("TrendingArticles: no pageviews for any of #{articles.size} candidates over #{WINDOW_DAYS}d (Plausible down or path mismatch?)")
  end
end
