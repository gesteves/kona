# Queries the Plausible Analytics API (v2). Redis caches each response for 5 minutes.
class Plausible < ApplicationService
  PLAUSIBLE_API_URL = "https://plausible.io/api/v2/query"
  # This matches an article page only. ArticleAttributes.path decides the format of that path.
  ARTICLE_PATH_FILTER = [ [ "matches", "event:page", [ "^/20\\d{2}/" ] ] ].freeze

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
  # ⚠️ This is ONE query for the full site, and both callers share it, on purpose. It is never one
  # query for each article. Plausible permits 600 calls each hour, and the 5-minute cache limits
  # each different query body to 12 calls each hour. Thus one shared key costs 12 calls each hour,
  # and a key for each article would grow with the number of articles and go past the limit. Do not
  # add a query for each article, and do not make the TTL shorter, until you do that calculation
  # again.
  #
  # @param date_range [String, Array] A Plausible date range: "all", or a [from, to] pair.
  # @return [Hash, nil] { path => pageviews }, or nil if the query is not available. That is what
  #   shows the difference between "the analytics are down" and "nobody read the page".
  def pageviews_by_path(date_range: "all")
    result = query(
      metrics: [ "pageviews" ],
      date_range: date_range,
      dimensions: [ "event:page" ],
      filters: ARTICLE_PATH_FILTER
    )
    return if result.nil?

    (result[:results] || []).each_with_object(Hash.new(0)) do |row, totals|
      path = normalize_path(row[:dimensions]&.first)
      next if path.blank?
      totals[path] += row[:metrics]&.first.to_i
    end
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

  # Plausible gives clean URLs, but the code adds an index.html at the end to the same path. Thus
  # the two forms give one total, and one of them does not go unused.
  def normalize_path(path)
    return if path.blank?
    path.to_s.sub(/index\.html\z/, "")
  end

  # ⚠️ This is a digest of the query, and not the query in a URL-safe form. That form removed the
  # regex characters from a filter such as ARTICLE_PATH_FILTER. Thus two different queries could
  # give the same key and each one could get the result of the other.
  def generate_cache_key(body)
    "plausible:query:#{cache_version(body.to_json)}"
  end
end
