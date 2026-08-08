# Queries the Plausible Analytics API (v2), caching responses in Redis for 5 minutes.
class Plausible < ApplicationService
  PLAUSIBLE_API_URL = "https://plausible.io/api/v2/query"
  # Matches only article pages, whose path format ArticleAttributes.path owns.
  ARTICLE_PATH_FILTER = [["matches", "event:page", ["^/20\\d{2}/"]]].freeze

  # @return [String, nil] The Plausible site id, or nil when unconfigured.
  attr_reader :site_id

  def initialize
    @access_token = ENV["PLAUSIBLE_API_KEY"]
    @site_id = ENV["PLAUSIBLE_SITE_ID"]
  end

  # The public dashboard URL for one page's stats. The path is URL-encoded before
  # interpolation, since a slug with URL-special characters would otherwise corrupt the filter.
  # @param path [String] The page path.
  # @param from [String] The range's start, as YYYY-MM-DD.
  # @param to [String] The range's end, as YYYY-MM-DD.
  # @return [String, nil] The URL, or nil when the site id isn't configured.
  def dashboard_url(path:, from:, to:)
    return if @site_id.blank?
    encoded_path = ERB::Util.url_encode(path)
    "https://plausible.io/#{@site_id}?f=is,page,#{encoded_path}&period=custom&from=#{from}&to=#{to}&r=v2"
  end

  # Pageviews for every article page over a date range.
  #
  # ⚠️ Deliberately ONE site-wide query, shared by both callers — never one query per article.
  # Plausible allows 600 calls/hour and the 5-minute cache caps each distinct query body at 12,
  # so one shared key costs 12 calls/hour flat while a key per article would scale with the
  # corpus and blow the limit. Don't reintroduce a per-article query or shorten the TTL without
  # redoing that math.
  #
  # @param date_range [String, Array] A Plausible date range: "all", or a [from, to] pair.
  # @return [Hash, nil] { path => pageviews }, or nil when the query is unavailable — which is
  #   what distinguishes "analytics are down" from "nothing has been viewed".
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

  # Runs a Plausible query, cached by request body.
  # @return [Hash, nil] The parsed response, or nil when unavailable.
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

  # Plausible reports clean URLs, but a trailing index.html is folded in so both forms sum into
  # one path rather than one going unmatched.
  def normalize_path(path)
    return if path.blank?
    path.to_s.sub(/index\.html\z/, "")
  end

  # ⚠️ A digest of the query, not a parameterized rendering of it. Parameterizing stripped the
  # regex characters out of filters like ARTICLE_PATH_FILTER, so two structurally different
  # queries could collide on one key and serve each other's results.
  def generate_cache_key(body)
    "plausible:query:#{cache_version(body.to_json)}"
  end
end
