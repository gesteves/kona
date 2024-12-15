require 'httparty'
require 'active_support/all'

# The PlausibleClient class interfaces with the Plausible API to fetch analytics data.
class Plausible
  PLAUSIBLE_API_URL = 'https://plausible.io/api/v2/query'

  # Initializes the PlausibleClient instance and fetches the analytics data.
  def initialize
    @access_token = ENV['PLAUSIBLE_API_KEY']
    @site_id = ENV['PLAUSIBLE_SITE_ID']
  end

  # Fetches the analytics data from the Plausible API and returns the results.
  # @return [Hash] A hash representing the API response.
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

    cache_key = "plausible:query:"
    cache_key += body.map do |key, value|
      if value.is_a?(Hash)
        value.map { |sub_key, sub_value| "#{key}.#{sub_key}:#{sub_value.to_s.parameterize}" }.join(':')
      elsif value.is_a?(Array)
        "#{key}:#{value.map(&:to_s).map(&:parameterize).join('-')}"
      else
        "#{key}:#{value.to_s.parameterize}"
      end
    end.join(':')
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    headers = {
      "Authorization" => "Bearer #{@access_token}",
      "Content-Type" => "application/json"
    }

    response = HTTParty.post(PLAUSIBLE_API_URL, headers: headers, body: body.to_json)
    return unless response.success?

    $redis.setex(cache_key, 1.hour, response.body)
    JSON.parse(response.body, symbolize_names: true)
  end
end
