require "set"

# Ranks the "Trending Articles" widget at request time as a "hot right now" signal: which articles are
# being read *more than their own normal*, right now. Recomputed each clock hour off a short, rolling,
# hour-granular Plausible window, so the widget genuinely changes through the day instead of echoing a
# slow 30-day average. The ranking is computed once per hour and shared; callers pick `all` (every hot
# article) or `excluding(ids)` (minus a caller-supplied set of Contentful ids — how an article page
# drops itself so it isn't listed as trending).
#
# Scoring (per article), from two Plausible queries anchored on the current clock hour:
#   * heat    = time-decayed recent pageviews, Σ pv_h · 0.5^(age_hours / HALF_LIFE_HOURS) over the last
#               RECENT_WINDOW_HOURS — recent hours count most, older ones taper off. This is the
#               absolute "how much attention is it getting now" term.
#   * baseline_rate = the article's normal pageviews/hour over the BASELINE_DAYS *before* the recent
#               window (so a surge can't inflate its own baseline), spread over the hours it existed.
#   * surge   = heat / (baseline_rate · S + K) — how much hotter than normal it is, where S is the
#               decay-weight sum (the heat we'd expect at the normal rate) and K smooths near-zero
#               baselines. This is the "having a moment" term the widget leans on.
#   * score   = log(surge + 1) · relative_weight + log(heat + 1) · absolute_weight
# Articles below MIN_RECENT_PAGEVIEWS of raw recent traffic score 0 (noise floor) and fall to the
# recency tail; articles too new to have a baseline rank on volume alone.
class TrendingArticles < ApplicationService
  # The rolling recent window (hours). Hour-granular so the ranking moves through the day; short so it
  # reflects "now" rather than a slow average. Env-overridable like the weights below.
  RECENT_WINDOW_HOURS = Integer(ENV.fetch("TRENDING_RECENT_WINDOW_HOURS", 72))
  # Decay half-life (hours): traffic this many hours old counts half as much. ~24h → the last day
  # dominates while older hours still contribute a little (so the pool doesn't collapse to nothing).
  HALF_LIFE_HOURS = Float(ENV.fetch("TRENDING_HALF_LIFE_HOURS", 24))
  # How far back the "normal rate" baseline reaches (days), ending where the recent window begins.
  BASELINE_DAYS = Integer(ENV.fetch("TRENDING_BASELINE_DAYS", 30))
  # Ignore articles with essentially no recent traffic — their surge ratios are pure noise.
  MIN_RECENT_PAGEVIEWS = 10
  # Poisson-style smoother in the surge denominator so a near-zero baseline can't explode the ratio.
  SMOOTHING = 1.0
  # Base of the exponential decay (0.5 == "half-life").
  DECAY_BASE = 0.5
  # Only article pages (paths like /2026/05/24/slug/), matching web's process_analytics filter.
  ARTICLE_PATH_FILTER = [["matches", "event:page", ["^/20\\d{2}/"]]].freeze
  # Cache and serve only the top slice of the ranking. A caller excludes at most the handful of cards
  # it shows, so this is always enough to fill `count` after exclusions, while bounding the JSON we
  # cache and the work each (potentially abusive) request does deserializing/filtering it.
  MAX_POOL = 50
  # The ranking is identical for every viewer within a clock hour, so memoize it for the hour (the
  # cache key carries the hour bucket, so it rolls over on its own).
  RESULT_TTL = 1.hour

  # @param articles [Articles] corpus source (injectable for testing)
  # @param plausible [Plausible] analytics source (injectable for testing)
  def initialize(articles: Articles.new, plausible: Plausible.new)
    @articles = articles
    @plausible = plausible
  end

  # The top `count` hot articles. @return [Array<OpenStruct>]
  def all(count: 4)
    ranked.first(count)
  end

  # The top `count` hot articles, minus any whose Contentful id is in `ids` — lets a caller drop the
  # cards it already shows on the page (an article page drops itself) so trending doesn't repeat them.
  # @return [Array<OpenStruct>]
  def excluding(ids, count: 4)
    excluded = Array(ids).to_set
    ranked.reject { |article| excluded.include?(article.sys&.id) }.first(count)
  end

  private

  # The full ranked list (corpus DeepOstructs, hottest first), computed once per clock hour and shared
  # by every variant. Cached under an hour-bucketed key so it rolls hourly and old hours expire; blank
  # (→ render_empty) on any error rather than raising.
  def ranked
    rescue_with([], context: self.class.name) do
      t_end = Time.now.beginning_of_hour
      items = cached_json("trending:articles:ranked:v4:#{t_end.utc.iso8601}", expires_in: RESULT_TTL) do
        rank(t_end).map { |article| payload(article) }
      end
      (items || []).map { |item| DeepOstruct.wrap(item) }
    end
  end

  # Ranks every candidate by "hot right now" score (returns the corpus DeepOstructs, hottest first).
  def rank(t_end)
    articles = candidates
    return [] if articles.blank?

    recent = recent_hourly_series(t_end)  # { path => { heat:, raw: } }
    baseline = baseline_totals(t_end)     # { path => total_pageviews }
    warn_if_no_analytics(articles, recent)

    baseline_end = t_end - (RECENT_WINDOW_HOURS * 3600)
    baseline_start = t_end - (BASELINE_DAYS * 86_400)
    # Parse each publish date exactly once (it's also the only thing here that can raise → rescued).
    published = articles.to_h { |article| [article.path, DateTime.parse(article.published_at)] }

    evaluated = articles.map do |article|
      score, heat = evaluate(recent[article.path], baseline[article.path].to_f, published[article.path], baseline_start, baseline_end)
      { article: article, score: score, heat: heat, published: published[article.path] }
    end

    # Sort by score, then heat, then recency — the last key orders the zero-scored tail newest-first,
    # so the widget fills to `count` with recent articles when little or nothing is hot. Keep only the
    # top pool: enough to fill after any legitimate exclusion, without caching the whole corpus.
    evaluated
      .sort_by { |e| [-e[:score], -e[:heat], -e[:published].to_time.to_i] }
      .first(MAX_POOL)
      .map { |e| e[:article] }
  end

  # Published, non-Short articles with a resolvable path (drafts/Shorts excluded — matches web).
  def candidates
    @articles.list.reject { |a| a.draft || a.entry_type == "Short" || a.path.blank? }
  end

  # One Plausible call → { path => { heat:, raw: } } for the recent window: `heat` is the time-decayed
  # pageview sum, `raw` the undecayed sum (for the eligibility floor). Decay age is measured from the
  # latest hour Plausible actually returned (robust to any site/server timezone drift), and the S
  # normalizer is a pure function of the window (see #decay_weights_sum).
  def recent_hourly_series(t_end)
    rows = @plausible.query(
      metrics: ["pageviews"],
      date_range: [(t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601, t_end.iso8601],
      dimensions: ["event:page", "time:hour"],
      filters: ARTICLE_PATH_FILTER
    )&.dig(:results) || []

    parsed = rows.filter_map do |row|
      path = normalize_path(row[:dimensions]&.first)
      hour = parse_hour(row[:dimensions] && row[:dimensions][1])
      next if path.blank? || hour.nil?
      [path, hour, row[:metrics]&.first.to_i]
    end
    return {} if parsed.empty?

    anchor = parsed.map { |(_path, hour, _pv)| hour }.max
    parsed.each_with_object({}) do |(path, hour, pv), by_path|
      age_hours = (anchor - hour) / 3600.0
      next if age_hours.negative? || age_hours >= RECENT_WINDOW_HOURS
      entry = (by_path[path] ||= { heat: 0.0, raw: 0 })
      entry[:heat] += pv * (DECAY_BASE**(age_hours / HALF_LIFE_HOURS))
      entry[:raw] += pv
    end
  end

  # One Plausible call → { path => total_pageviews } over the baseline period (the BASELINE_DAYS ending
  # where the recent window begins), used to derive each article's normal pageviews/hour.
  def baseline_totals(t_end)
    rows = @plausible.query(
      metrics: ["pageviews"],
      date_range: [(t_end - (BASELINE_DAYS * 86_400)).iso8601, (t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601],
      dimensions: ["event:page"],
      filters: ARTICLE_PATH_FILTER
    )&.dig(:results) || []

    rows.each_with_object({}) do |row, totals|
      path = normalize_path(row[:dimensions]&.first)
      next if path.blank?
      totals[path] = row[:metrics]&.first.to_i
    end
  end

  # Scores one article. Returns [score, heat] (heat is the tiebreaker). Below the recent-traffic floor
  # → [0, 0] (sorts into the recency tail). Too new for a baseline → volume-only.
  def evaluate(recent, baseline_total, published, baseline_start, baseline_end)
    recent ||= { heat: 0.0, raw: 0 }
    return [0.0, 0.0] if recent[:raw] < MIN_RECENT_PAGEVIEWS

    heat = recent[:heat]
    volume = Math.log(heat + 1)

    # Hours the article existed within the baseline window (before the recent window), so a young post
    # isn't penalized for the pre-publish days it didn't exist.
    existed_from = [published.to_time, baseline_start].max
    baseline_hours = (baseline_end - existed_from) / 3600.0

    score =
      if baseline_hours <= 0
        # Too new to have a trustworthy baseline → rank on recent volume alone (mirrors the old model's
        # young-post branch), so a launch burst still surfaces without an infinite surge ratio.
        volume * absolute_weight
      else
        baseline_rate = baseline_total / baseline_hours
        expected_heat = baseline_rate * decay_weights_sum
        surge = heat / (expected_heat + SMOOTHING)
        Math.log(surge + 1) * relative_weight + volume * absolute_weight
      end

    [score, heat]
  end

  # Σ over the window of the per-hour decay weights — the heat an article would accrue at a steady rate
  # of one pageview/hour, i.e. the normalizer that turns baseline_rate into an expected heat. Constant
  # for a given window/half-life, so memoized.
  def decay_weights_sum
    @decay_weights_sum ||= (0...RECENT_WINDOW_HOURS).sum { |i| DECAY_BASE**(i / HALF_LIFE_HOURS) }
  end

  def relative_weight
    @relative_weight ||= ENV.fetch("TRENDING_SCORE_RELATIVE_WEIGHT", 1).to_f
  end

  # Defaults below 1 so the volume term stays a guard (keeping a 0→3 blip from outranking a real surge)
  # while the surge term leads — the widget is "having a moment", not "most-read of all time".
  def absolute_weight
    @absolute_weight ||= ENV.fetch("TRENDING_SCORE_ABSOLUTE_WEIGHT", 0.5).to_f
  end

  # Plausible reports clean URLs already, but normalize any trailing index.html to match paths.
  def normalize_path(path)
    return if path.blank?
    path.to_s.sub(/index\.html\z/, "")
  end

  # Parses a Plausible time:hour bucket label ("YYYY-MM-DD HH:MM:SS") to a Time, or nil if unparseable.
  def parse_hour(label)
    return if label.blank?
    Time.parse(label.to_s)
  rescue ArgumentError
    nil
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

  # Cheap signal for "analytics unavailable or a path-format regression": candidates present but zero
  # recent pageviews for all of them → trending silently collapses to recency order.
  def warn_if_no_analytics(articles, recent)
    return if articles.any? { |a| recent[a.path]&.fetch(:raw, 0).to_i.positive? }
    Rails.logger.info("TrendingArticles: no recent pageviews for any of #{articles.size} candidates over #{RECENT_WINDOW_HOURS}h (Plausible down or path mismatch?)")
  end
end
