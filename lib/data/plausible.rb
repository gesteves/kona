require 'httparty'
require 'active_support/all'

# The PlausibleClient class interfaces with the Plausible API to fetch analytics data.
class Plausible
  PLAUSIBLE_API_URL = 'https://plausible.io/api/v2/query'

  # Initializes the PlausibleClient instance and fetches the analytics data.
  def initialize
    @access_token = ENV['PLAUSIBLE_API_KEY']
    @site_id = ENV['PLAUSIBLE_SITE_ID']
    @data = fetch_analytics_data
  end

  # Saves the fetched data into a JSON file.
  def save_data
    metrics = @data[:query][:metrics]
    results = @data[:results]

    # Build the JSON data with keys for each metric, sorting paths by the corresponding metric values
    json_data = metrics.each_with_object({}) do |metric, output|
      metric_index = metrics.index(metric)
      output[metric] = results
        .sort_by { |result| -result[:metrics][metric_index] }
        .map { |result| result[:dimensions].first }
    end

    File.open('data/plausible.json', 'w') { |f| f << json_data.to_json }
  end

  private

  # Fetches the analytics data from the Plausible API and returns the results.
  # @return [Hash] A hash representing the API response.
  def fetch_analytics_data
    return if @access_token.blank? || @site_id.blank?

    body = {
      site_id: @site_id,
      metrics: ["pageviews", "visits"],
      dimensions: ["event:page"],
      filters: [["matches", "event:page", ["^/20\\d{2}/"]]],
      order_by: [["pageviews", "desc"]],
      pagination: { offset: 0, limit: 1000 }
    }

    cache_key = "plausible:#{body.to_s.parameterize}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    headers = {
      "Authorization" => "Bearer #{@access_token}",
      "Content-Type" => "application/json"
    }

    body[:date_range] = [
      1.day.ago.iso8601,
      Time.current.iso8601
    ]

    response = HTTParty.post(PLAUSIBLE_API_URL, headers: headers, body: body.to_json)
    return unless response.success?

    data = JSON.parse(response.body, symbolize_names: true)
    $redis.setex(cache_key, 1.hour, response.body)
    data
  end
end
