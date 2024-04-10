require 'httparty'
require 'active_support/all'

# The DarkVisitors class interfaces with the DarkVisitors API to fetch and process robots.txt data.
class DarkVisitors
  DARK_VISITORS_API_URL = 'https://api.darkvisitors.com'

  # Initializes the DarkVisitors instance by fetching the robots.txt data from the API.
  def initialize
    @access_token = ENV['DARK_VISITORS_ACCESS_TOKEN']
    @data = fetch_robots_txt
  end

  # Saves the fetched robots.txt data into a JSON file.
  def save_data
    json_data = { robots_txt: @data }
    File.open('data/dark_visitors.json', 'w') { |f| f << json_data.to_json }
  end

  private

  # Fetches the robots.txt data from the DarkVisitors API, caches it in Redis, and returns it.
  # @return [String] The robots.txt data as a string.
  def fetch_robots_txt
    return if ENV['DARK_VISITORS_ACCESS_TOKEN'].blank?

    cache_key = "darkvisitors:robots_txt"
    data = $redis.get(cache_key)

    return data if data.present?

    headers = {
      "Authorization" => "Bearer #{@access_token}",
      "Content-Type" => "application/json"
    }

    body = {
      agent_types: ["AI Data Scraper"],
      disallow: "/"
    }

    response = HTTParty.post("#{DARK_VISITORS_API_URL}/robots-txts", headers: headers, body: body.to_json)
    return unless response.success?

    data = response.body
    $redis.setex(cache_key, 1.day, data)

    data
  end
end

