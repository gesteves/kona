# Queries the Plausible Analytics API (v2). Redis caches each response for 5 minutes.
class Plausible < ApplicationService
  PLAUSIBLE_API_URL = "https://plausible.io/api/v2/query"
  # This matches an article page only. ArticleAttributes.path decides the format of that path.
  ARTICLE_PATH_FILTER = [ [ "matches", "event:page", [ "^/20\\d{2}/" ] ] ].freeze
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

  # The unique visitors of each article page on each day of the last `days` days, and today. One
  # query body gives the full series, and TrendingArticles calculates each window from it.
  #
  # ⚠️ The metric is the visitors and not the pageviews. It counts a reader one time however many
  # times they load the page, thus a reload cannot raise it.
  # ⚠️ The answer has one row for each day and each page with traffic: approximately 100 days by 50
  # pages today, below the page limit of `query`. Read the warning of `query` before you make
  # `days` much larger.
  # @param days [Integer] The number of days before today.
  # @param today [Date] The last day of the series. It is a partial day, on purpose.
  # @return [Hash{String=>Hash{Date=>Integer}}, nil] { path => { day => visitors } }, or nil if the
  #   query is not available. A day with no row is absent, and a caller reads it as 0.
  def daily_visitors_by_path(days:, today: site_today)
    result = query(
      metrics: [ "visitors" ],
      date_range: [ (today - days).iso8601, today.iso8601 ],
      dimensions: [ "time:day", "event:page" ],
      filters: ARTICLE_PATH_FILTER
    )
    return if result.nil?

    (result[:results] || []).each_with_object({}) do |row, series|
      day_text, page = row[:dimensions]
      path = normalize_path(page)
      day = parse_day(day_text)
      next if path.blank? || day.nil?

      (series[path] ||= Hash.new(0))[day] += Array(row[:metrics]).first.to_i
    end
  end

  # The unique visitors who went from one article page to another one in the same visit.
  # `rake related:evaluate` reads it, and the request path never does.
  # @param date_range [String, Array] A Plausible date range: "all", or a [from, to] pair.
  # @return [Hash{String=>Hash{String=>Integer}}, nil] { entry path => { path => visitors } }, or
  #   nil if the query is not available. The pair with the same path on both sides is absent.
  def covisit_visitors(date_range: "all")
    result = query(
      metrics: [ "visitors" ],
      date_range: date_range,
      dimensions: [ "visit:entry_page", "event:page" ],
      filters: ARTICLE_PATH_FILTER
    )
    return if result.nil?

    (result[:results] || []).each_with_object({}) do |row, transitions|
      from, to = Array(row[:dimensions]).map { |page| normalize_path(page) }
      next if from.blank? || to.blank? || from == to

      (transitions[from] ||= Hash.new(0))[to] += Array(row[:metrics]).first.to_i
    end
  end

  # Today in the zone of the site, which is the zone that Plausible reports each day in.
  # @return [Date]
  def site_today
    Time.now.in_time_zone(TimeZoneResolver.default).to_date
  end

  # Does a Plausible query. The request body is the cache key.
  # @return [Hash, nil] The parsed response, or nil if it is not available.
  # ⚠️ One page only. `limit` is far above the number of pages of this site, and the code writes a
  # warning when an answer reaches it: a row past the limit would score zero with no message.
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
      result = post_json(PLAUSIBLE_API_URL, headers: headers, body: body.to_json)
      if result && Array(result[:results]).size >= limit
        Rails.logger.warn("Plausible: an answer reached the page limit of #{limit} rows; rows past it are absent")
      end
      result
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

  # @return [Date, nil] The day of a `time:day` dimension, or nil for a value with an error.
  def parse_day(text)
    Date.iso8601(text.to_s)
  rescue Date::Error
    nil
  end

  # ⚠️ This is a digest of the query, and not the query in a URL-safe form. That form removed the
  # regex characters from a filter such as ARTICLE_PATH_FILTER. Thus two different queries could
  # give the same key and each one could get the result of the other.
  def generate_cache_key(body)
    "plausible:query:#{cache_version(body.to_json)}"
  end
end
