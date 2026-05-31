# Ranks the home page's "Trending Articles" at request time from Plausible analytics, replacing the
# build-time bake. Loads the published article corpus (Articles#list) plus the 1d/7d/30d/all pageview
# windows, scores each article by how much its traffic is spiking, and returns the non-recent trending
# set. Mirrors the static site's article_helpers ranking.
class TrendingArticles < ApplicationService
  WINDOWS = %w[all 30d 7d 1d].freeze
  # Only article pages (paths like /2026/05/24/slug/), matching web's process_analytics filter.
  ARTICLE_PATH_FILTER = [["matches", "event:page", ["^/20\\d{2}/"]]].freeze

  # The home page's trending set: the top trending articles, minus the N most recent, capped at N.
  # @return [Array<OpenStruct>]
  def non_recent(count: 4)
    articles = candidates
    return [] if articles.blank?

    pv = pageviews_by_window
    trending = articles
      .sort_by { |a| [-score(a, pv), -pageviews(a, pv, "7d"), -pageviews(a, pv, "30d")] }
      .take(count * 2)
    recent_paths = articles.sort_by { |a| -published_int(a) }.take(count).map(&:path)

    trending.reject { |a| recent_paths.include?(a.path) }.take(count)
  end

  private

  # Published, non-Short articles with a resolvable path (drafts/Shorts excluded — matches web).
  def candidates
    Articles.new.list.reject { |a| a.draft || a.entry_type == "Short" || a.path.blank? }
  end

  # { "1d" => { path => pageviews }, "7d" => {...}, ... } across every window.
  def pageviews_by_window
    plausible = Plausible.new
    WINDOWS.each_with_object({}) do |window, windows|
      results = plausible.query(metrics: ["pageviews"], date_range: window, dimensions: ["event:page"], filters: ARTICLE_PATH_FILTER)&.dig(:results) || []
      windows[window] = results.each_with_object({}) do |result, paths|
        path = normalize_path(result[:dimensions]&.first)
        paths[path] = result[:metrics]&.first.to_i if path.present?
      end
    end
  end

  def pageviews(article, pv, window)
    pv.dig(window, article.path).to_i
  end

  # The spike score: today's views relative to the article's normal traffic, blending a relative
  # (vs. its own baseline) and an absolute (vs. all-time average) signal. Ported verbatim from
  # article_helpers#absolute_trending_score. Returns 0 with no recent activity.
  def score(article, pv)
    relative_weight = ENV.fetch("TRENDING_SCORE_RELATIVE_WEIGHT", 1).to_f
    absolute_weight = ENV.fetch("TRENDING_SCORE_ABSOLUTE_WEIGHT", 1).to_f

    daily = pageviews(article, pv, "1d").to_f
    week_avg = pageviews(article, pv, "7d").to_f / 7
    all_time_avg = pageviews(article, pv, "all").to_f / days_since_published(article)
    return 0 if daily.zero? || week_avg.zero? || all_time_avg.zero?

    baseline = [week_avg, all_time_avg].max
    (daily / baseline * relative_weight) + (daily / all_time_avg * absolute_weight)
  end

  def days_since_published(article)
    [((Time.now - DateTime.parse(article.published_at)) / 1.day).ceil, 1].max
  end

  def published_int(article)
    DateTime.parse(article.published_at).to_i
  end

  # Plausible reports clean URLs already, but normalize any trailing index.html to match paths.
  def normalize_path(path)
    return if path.blank?
    path.to_s.sub(/index\.html\z/, "")
  end
end
