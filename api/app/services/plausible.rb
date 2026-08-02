# Queries the Plausible Analytics API (v2). Ported from the web app's lib/data/plausible.rb.
# Raw responses are cached in Redis for 5 minutes.
class Plausible < ApplicationService
  PLAUSIBLE_API_URL = "https://plausible.io/api/v2/query"
  # Only article pages (paths like /2026/05/24/slug/, the format ArticleAttributes.path owns),
  # matching web's process_analytics filter.
  ARTICLE_PATH_FILTER = [["matches", "event:page", ["^/20\\d{2}/"]]].freeze

  # The Plausible site id (the domain the dashboard lives under), or nil when unconfigured.
  attr_reader :site_id

  def initialize
    @access_token = ENV["PLAUSIBLE_API_KEY"]
    @site_id = ENV["PLAUSIBLE_SITE_ID"]
  end

  # The public dashboard URL for one page's stats over a date range, or nil when the site id
  # isn't configured. URL-encodes the path before interpolating it into the query string; a
  # slug containing URL-special characters would otherwise corrupt the f=is,page filter /
  # inject params.
  # @param path [String] The page path (e.g. "/2026/05/01/my-race-report/").
  # @param from [String] The range start (YYYY-MM-DD).
  # @param to [String] The range end (YYYY-MM-DD).
  # @return [String, nil]
  def dashboard_url(path:, from:, to:)
    return if @site_id.blank?
    encoded_path = ERB::Util.url_encode(path)
    "https://plausible.io/#{@site_id}?f=is,page,#{encoded_path}&period=custom&from=#{from}&to=#{to}&r=v2"
  end

  # Pageviews for every article page over `date_range`, as { path => pageviews }.
  #
  # ⚠️ This is deliberately ONE site-wide query rather than one query per article, and both
  # callers (the per-article pageviews widget and TrendingArticles) share it for that reason.
  # Plausible allows 600 calls/hour; `query` caches each distinct body for 5 minutes, so the
  # ceiling is 12 calls/hour per *cache key*. Asking per article would mint a key per article
  # (~60 and growing with the corpus) and put the ceiling over the limit — see the note in
  # Widgets::PlausibleController. Keep it one query.
  #
  # @param date_range [String, Array] A Plausible date range ("all", or a [from, to] pair).
  # @return [Hash, nil] { path => pageviews }, or nil when the query is unavailable — which
  #   distinguishes "analytics are down" from "nothing has been viewed".
  def pageviews_by_path(date_range: "all")
    result = query(
      metrics: ["pageviews"],
      date_range: date_range,
      dimensions: ["event:page"],
      filters: ARTICLE_PATH_FILTER
    )
    return if result.nil?

    (result[:results] || []).each_with_object(Hash.new(0)) do |row, totals|
      path = normalize_path(row[:dimensions]&.first)
      next if path.blank?
      totals[path] += row[:metrics]&.first.to_i
    end
  end

  # @return [Hash, nil] The parsed API response, or nil if unavailable.
  def query(metrics: [], date_range: "all", dimensions: ["event:page"], filters: nil, order_by: nil, offset: 0, limit: 10000)
    return if @access_token.blank? || @site_id.blank?

    if date_range == "1d"
      today = Time.now.beginning_of_hour
      yesterday = today - 1.day
      date_range = [yesterday.iso8601, today.iso8601]
    end

    body = {
      site_id: @site_id,
      metrics: metrics,
      date_range: date_range,
      dimensions: dimensions,
      filters: filters,
      order_by: order_by,
      pagination: { offset: offset, limit: limit }
    }.compact

    cached_json(generate_cache_key(body), expires_in: 5.minutes) do
      headers = {
        "Authorization" => "Bearer #{@access_token}",
        "Content-Type" => "application/json"
      }
      post_json(PLAUSIBLE_API_URL, headers: headers, body: body.to_json)
    end
  end

  private

  # Plausible reports clean URLs already, but normalize any trailing index.html so both forms
  # fold into the one path (summing them, rather than one of them going unmatched).
  def normalize_path(path)
    return if path.blank?
    path.to_s.sub(/index\.html\z/, "")
  end

  def generate_cache_key(body)
    "plausible:query:" + body.map do |key, value|
      if value.is_a?(Hash)
        value.map { |sub_key, sub_value| "#{key}.#{sub_key}:#{sub_value.to_s.parameterize}" }.join(":")
      elsif value.is_a?(Array)
        "#{key}:#{value.map(&:to_s).map(&:parameterize).join('-')}"
      else
        "#{key}:#{value.to_s.parameterize}"
      end
    end.join(":")
  end
end
