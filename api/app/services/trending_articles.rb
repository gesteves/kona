require "set"

# Ranks the "Trending Articles" widget at request time as a "hot today" signal: which articles are
# being read *more than their own normal* over roughly the last day or two. Recomputed each clock hour
# off a short, rolling Plausible window, so the widget moves through the day (as the window rolls and
# today's pageviews accrue) without the hour-to-hour jumpiness a "right now" signal would have on a
# low-traffic site. The ranking is computed once per hour and shared; callers pick `all` (every hot
# article) or `excluding(ids)` (minus a caller-supplied set of Contentful ids — how an article page
# drops itself so it isn't listed as trending).
#
# Scoring (per article), from two Plausible queries anchored on the current clock hour:
#   * heat    = pageviews over the last RECENT_WINDOW_HOURS (a flat window — every view in the window
#               counts equally, so a post read this morning still counts tonight). The absolute "how
#               much attention is it getting" term.
#   * baseline_rate = the article's normal pageviews/hour over the BASELINE_DAYS *before* the recent
#               window (so a surge can't inflate its own baseline), spread over the hours it existed.
#   * surge   = heat / (baseline_rate · RECENT_WINDOW_HOURS + K) — how much hotter than normal it is
#               (K smooths near-zero baselines). This is the "having a moment" term the widget leans on.
#   * score   = log(surge + 1) · relative_weight + log(heat + 1) · absolute_weight
# Articles below MIN_RECENT_PAGEVIEWS of recent traffic score 0 (noise floor) and fall to the recency
# tail; articles too new to have a baseline rank on volume alone.
class TrendingArticles < ApplicationService
  # The rolling recent window (hours). Short enough to be "recent/today", long enough to accumulate a
  # usable signal on a low-traffic site. Env-overridable like the weights below.
  RECENT_WINDOW_HOURS = Integer(ENV.fetch("TRENDING_RECENT_WINDOW_HOURS", 48))
  # How far back the "normal rate" baseline reaches (days), ending where the recent window begins.
  BASELINE_DAYS = Integer(ENV.fetch("TRENDING_BASELINE_DAYS", 30))
  # Ignore articles with essentially no recent traffic — their surge ratios are pure noise.
  MIN_RECENT_PAGEVIEWS = 5
  # Poisson-style smoother in the surge denominator so a near-zero baseline can't explode the ratio.
  SMOOTHING = 1.0
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

  # Ranks every candidate by "hot today" score (returns the corpus DeepOstructs, hottest first).
  def rank(t_end)
    articles = candidates
    return [] if articles.blank?

    recent = pageviews_by_path(date_range: [(t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601, t_end.iso8601])
    baseline = pageviews_by_path(date_range: [(t_end - (BASELINE_DAYS * 86_400)).iso8601, (t_end - (RECENT_WINDOW_HOURS * 3600)).iso8601])
    warn_if_no_analytics(articles, recent)

    baseline_end = t_end - (RECENT_WINDOW_HOURS * 3600)
    baseline_start = t_end - (BASELINE_DAYS * 86_400)
    # Parse each publish date exactly once (it's also the only thing here that can raise → rescued).
    published = articles.to_h { |article| [article.path, DateTime.parse(article.published_at)] }

    evaluated = articles.map do |article|
      score, heat = evaluate(recent[article.path].to_i, baseline[article.path].to_f, published[article.path], baseline_start, baseline_end)
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

  # One Plausible call → { path => total_pageviews } over the given date range (a flat per-page count).
  # Used for both the recent window and the baseline period.
  def pageviews_by_path(date_range:)
    rows = @plausible.query(
      metrics: ["pageviews"],
      date_range: date_range,
      dimensions: ["event:page"],
      filters: ARTICLE_PATH_FILTER
    )&.dig(:results) || []

    rows.each_with_object(Hash.new(0)) do |row, totals|
      path = normalize_path(row[:dimensions]&.first)
      next if path.blank?
      totals[path] += row[:metrics]&.first.to_i
    end
  end

  # Scores one article. Returns [score, heat] (heat is the tiebreaker). Below the recent-traffic floor
  # → [0, 0] (sorts into the recency tail). Too new for a baseline → volume-only.
  def evaluate(recent_pageviews, baseline_total, published, baseline_start, baseline_end)
    return [0.0, 0.0] if recent_pageviews < MIN_RECENT_PAGEVIEWS

    volume = Math.log(recent_pageviews + 1)

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
        baseline_rate = baseline_total / baseline_hours                 # pageviews/hour
        expected = baseline_rate * RECENT_WINDOW_HOURS                  # expected pageviews over the window
        surge = recent_pageviews / (expected + SMOOTHING)
        Math.log(surge + 1) * relative_weight + volume * absolute_weight
      end

    [score, recent_pageviews.to_f]
  end

  def relative_weight
    @relative_weight ||= ENV.fetch("TRENDING_SCORE_RELATIVE_WEIGHT", 1).to_f
  end

  # Defaults below 1 so the volume term stays a guard (keeping a small blip from outranking a real
  # surge) while the surge term leads — the widget is "having a moment", not "most-read of all time".
  def absolute_weight
    @absolute_weight ||= ENV.fetch("TRENDING_SCORE_ABSOLUTE_WEIGHT", 0.5).to_f
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

  # Cheap signal for "analytics unavailable or a path-format regression": candidates present but zero
  # recent pageviews for all of them → trending silently collapses to recency order.
  def warn_if_no_analytics(articles, recent)
    return if articles.any? { |a| recent[a.path].to_i.positive? }
    Rails.logger.info("TrendingArticles: no recent pageviews for any of #{articles.size} candidates over #{RECENT_WINDOW_HOURS}h (Plausible down or path mismatch?)")
  end
end
