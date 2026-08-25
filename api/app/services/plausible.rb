# Queries the Plausible Analytics API (v2). Redis caches each response for 5 minutes.
class Plausible < ApplicationService
  PLAUSIBLE_API_URL = "https://plausible.io/api/v2/query"
  # This matches an article page only. ArticleAttributes.path decides the format of that path.
  ARTICLE_PATH_FILTER = [ [ "matches", "event:page", [ "^/20\\d{2}/" ] ] ].freeze
  # The same match against the page where a session started.
  ENTRY_PATH_FILTER = [ [ "matches", "visit:entry_page", [ "^/20\\d{2}/" ] ] ].freeze
  # The metrics of the all-time query. One query body gives both, thus the pageviews widget and
  # the fallback of TrendingArticles share one call.
  TOTAL_METRICS = %w[visitors pageviews].freeze

  # @return [String, nil] The Plausible site id, or nil if there is no configuration.
  attr_reader :site_id

  def initialize
    @access_token = ENV["PLAUSIBLE_API_KEY"]
    @site_id = ENV["PLAUSIBLE_SITE_ID"]
  end

  # The public dashboard URL for the stats of one page. The code changes the path into a URL-safe
  # form first, because a slug with a character that has a meaning in a URL would break the filter.
  # @param path [String] The path of the page.
  # @param from [String] The start of the range, as YYYY-MM-DD.
  # @param to [String] The end of the range, as YYYY-MM-DD.
  # @return [String, nil] The URL, or nil if there is no site id in the configuration.
  def dashboard_url(path:, from:, to:)
    return if @site_id.blank?
    encoded_path = ERB::Util.url_encode(path)
    "https://plausible.io/#{@site_id}?f=is,page,#{encoded_path}&period=custom&from=#{from}&to=#{to}&r=v2"
  end

  # The pageviews of each article page over a date range.
  #
  # ⚠️ Each query here is ONE query for the full site, and it is never one query for each article.
  # Plausible permits 600 calls each hour, and the 5-minute cache limits each different query body
  # to 12 calls each hour. Thus each shared key costs 12 calls each hour, and a key for each
  # article would grow with the number of articles and go past the limit. Do not add a query for
  # each article, and do not make the TTL shorter, until you do that calculation again.
  #
  # @param date_range [String, Array] A Plausible date range: "all", or a [from, to] pair.
  # @return [Hash, nil] { path => pageviews }, or nil if the query is not available. That is what
  #   shows the difference between "the analytics are down" and "nobody read the page".
  def pageviews_by_path(date_range: "all")
    column(totals_by_path(date_range: date_range), :pageviews)
  end

  # The visitors and the pageviews of each article page over a date range.
  #
  # ⚠️ This is ONE query body for both metrics, on purpose. The pageviews widget reads the
  # pageviews, and TrendingArticles reads the visitors for its fallback. Two queries would cost
  # two keys and give the same data.
  # @param date_range [String, Array] A Plausible date range: "all", or a [from, to] pair.
  # @return [Hash, nil] { path => { visitors:, pageviews: } }, or nil if the query is not
  #   available.
  def totals_by_path(date_range: "all")
    fold(
      query(
        metrics: TOTAL_METRICS,
        date_range: date_range,
        dimensions: [ "event:page" ],
        filters: ARTICLE_PATH_FILTER
      ),
      TOTAL_METRICS
    )
  end

  # The unique visitors of each article page over a date range, and it counts each one time however
  # they arrived.
  #
  # ⚠️ A click inside the site goes into this number, and the trending widget renders on the home
  # page and on each Page. Thus the widget can put its own clicks here, and its output would then
  # order its own input. TrendingArticles gives this part of the signal a weight below 1 for that
  # reason. Refer to TrendingArticles::INTERNAL_WEIGHT.
  # @param date_range [String, Array] A Plausible date range: "all", or a [from, to] pair.
  # @return [Hash, nil] { path => visitors }, or nil if the query is not available.
  def page_visitors_by_path(date_range: "all")
    column(totals_by_path(date_range: date_range), :visitors)
  end

  # The unique visitors whose session STARTED on each article page.
  #
  # ⚠️ A session that starts on the article measures the demand from OUTSIDE the site, and no click
  # inside the site can change it. TrendingArticles reads this together with
  # page_visitors_by_path, and it gives this part the full weight.
  #
  # @param date_range [String, Array] A Plausible date range: "all", or a [from, to] pair.
  # @return [Hash, nil] { path => visitors }, or nil if the query is not available. That is what
  #   shows the difference between "the analytics are down" and "nobody read the page".
  def entry_visitors_by_path(date_range: "all")
    totals = fold(
      query(
        metrics: [ "visitors" ],
        date_range: date_range,
        dimensions: [ "visit:entry_page" ],
        filters: ENTRY_PATH_FILTER
      ),
      [ "visitors" ]
    )

    column(totals, :visitors)
  end

  # Does a Plausible query. The request body is the cache key.
  # @return [Hash, nil] The parsed response, or nil if it is not available.
  def query(metrics: [], date_range: "all", dimensions: [ "event:page" ], filters: nil, order_by: nil, offset: 0, limit: 10000)
    return if @access_token.blank? || @site_id.blank?

    body = {
      site_id: @site_id,
      metrics: metrics,
      date_range: date_range,
      dimensions: dimensions,
      filters: filters,
      order_by: order_by,
      pagination: { offset: offset, limit: limit }
    }.compact

    # ⚠️ empty_expires_in is the wait for the rate limit, and not a cache. Plausible permits 600
    # calls each hour, and post_json returns nil for each non-2xx. Thus without it, each subsequent
    # request after a 429 would query again with no limit. The rate-limit failure would then remove
    # its own protection.
    cached_json(generate_cache_key(body), expires_in: 5.minutes, empty_expires_in: 1.minute) do
      headers = {
        "Authorization" => "Bearer #{@access_token}",
        "Content-Type" => "application/json"
      }
      post_json(PLAUSIBLE_API_URL, headers: headers, body: body.to_json)
    end
  end

  private

  # Folds the rows of a response into one hash for each path.
  # @param result [Hash, nil] The parsed response.
  # @param metrics [Array<String>] The metric names, in the order that the query asked for them.
  # @return [Hash, nil] { path => { metric => total } }, or nil for a query that failed.
  def fold(result, metrics)
    return if result.nil?

    (result[:results] || []).each_with_object({}) do |row, totals|
      path = normalize_path(row[:dimensions]&.first)
      next if path.blank?

      values = Array(row[:metrics])
      bucket = (totals[path] ||= metrics.each_with_object({}) { |m, h| h[m.to_sym] = 0 })
      metrics.each_with_index { |metric, index| bucket[metric.to_sym] += values[index].to_i }
    end
  end

  # Takes one metric out of a folded result.
  # @return [Hash, nil] { path => total }, with a default of 0, or nil for a query that failed.
  def column(totals, metric)
    return if totals.nil?

    totals.each_with_object(Hash.new(0)) { |(path, values), out| out[path] = values[metric].to_i }
  end

  # Plausible gives clean URLs, but the code adds an index.html at the end to the same path. Thus
  # the two forms give one total, and one of them does not go unused.
  #
  # ⚠️ It also adds the slash at the end. ArticleAttributes.path always writes one, thus a path
  # from Plausible with no slash would never join to an article and would count as zero.
  def normalize_path(path)
    return if path.blank?

    normalized = path.to_s.sub(/index\.html\z/, "")
    normalized.end_with?("/") ? normalized : "#{normalized}/"
  end

  # ⚠️ This is a digest of the query, and not the query in a URL-safe form. That form removed the
  # regex characters from a filter such as ARTICLE_PATH_FILTER. Thus two different queries could
  # give the same key and each one could get the result of the other.
  def generate_cache_key(body)
    "plausible:query:#{cache_version(body.to_json)}"
  end
end
