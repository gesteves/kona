require "set"

# Ranks the home page's "Trending Articles" at request time from Plausible analytics, replacing the
# build-time bake. Loads the published article corpus (Articles#list) plus the recent pageview
# windows, scores each article by how much its traffic is spiking, and returns the non-recent
# trending set. Mirrors the static site's article_helpers ranking.
class TrendingArticles < ApplicationService
  # Pageview windows pulled from Plausible: 1d/7d feed the spike, "all" is the lifetime baseline.
  # (The old "30d" window was only a third-level sort tiebreaker — not worth a fourth HTTP call.)
  WINDOWS = %w[all 7d 1d].freeze
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
      items = cached_json("trending:articles:non_recent:v1:count:#{count}", expires_in: RESULT_TTL) do
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

    metrics = pageviews_by_window
    warn_if_no_analytics(articles, metrics)

    # Parse each publish date exactly once (it's also the only thing here that can raise).
    published = articles.to_h { |article| [article.path, DateTime.parse(article.published_at)] }

    trending = articles
      .sort_by { |a| [-score(a, metrics, published), -pageviews(a, metrics, "7d")] }
      .take(count * CANDIDATE_MULTIPLIER)
    recent_paths = Set.new(articles.max_by(count) { |a| published[a.path] }.map(&:path))

    trending.reject { |a| recent_paths.include?(a.path) }.take(count)
  end

  # Published, non-Short articles with a resolvable path (drafts/Shorts excluded — matches web).
  def candidates
    @articles.list.reject { |a| a.draft || a.entry_type == "Short" || a.path.blank? }
  end

  # { "1d" => { path => pageviews }, "7d" => {...}, "all" => {...} } across every window.
  def pageviews_by_window
    WINDOWS.each_with_object({}) do |window, windows|
      results = @plausible.query(metrics: ["pageviews"], date_range: window, dimensions: ["event:page"], filters: ARTICLE_PATH_FILTER)&.dig(:results) || []
      windows[window] = results.each_with_object({}) do |result, paths|
        path = normalize_path(result[:dimensions]&.first)
        paths[path] = result[:metrics]&.first.to_i if path.present?
      end
    end
  end

  def pageviews(article, metrics, window)
    metrics.dig(window, article.path).to_i
  end

  # The spike score: today's views relative to the article's normal traffic, blending a relative
  # (vs. its own baseline) and an absolute (vs. all-time average) signal. Ported from
  # article_helpers#absolute_trending_score. Returns 0 with no recent activity.
  def score(article, metrics, published)
    daily = pageviews(article, metrics, "1d").to_f
    week_avg = pageviews(article, metrics, "7d").to_f / 7
    all_time_avg = pageviews(article, metrics, "all").to_f / days_since_published(published[article.path])
    return 0 if daily.zero? || week_avg.zero? || all_time_avg.zero?

    baseline = [week_avg, all_time_avg].max
    (daily / baseline * relative_weight) + (daily / all_time_avg * absolute_weight)
  end

  def relative_weight
    @relative_weight ||= ENV.fetch("TRENDING_SCORE_RELATIVE_WEIGHT", 1).to_f
  end

  def absolute_weight
    @absolute_weight ||= ENV.fetch("TRENDING_SCORE_ABSOLUTE_WEIGHT", 1).to_f
  end

  def days_since_published(date)
    [((Time.now - date) / 1.day).ceil, 1].max
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

  # Cheap signal for "analytics unavailable or a path-format regression": with candidates present
  # but zero all-time pageviews for all of them, trending silently collapses to recency order.
  def warn_if_no_analytics(articles, metrics)
    return if articles.any? { |a| pageviews(a, metrics, "all").positive? }
    Rails.logger.info("TrendingArticles: no all-time pageviews for any of #{articles.size} candidates (Plausible down or path mismatch?)")
  end
end
