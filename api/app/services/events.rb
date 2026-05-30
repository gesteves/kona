require "httparty"

# Fetches race events from Contentful with a small, targeted GraphQL query — just the
# fields the weather widget needs to spot today's race (title, date, going, trackingUrl).
# Cached in Redis for 10 minutes. `all` returns an array wrapped for dot-access.
class Events
  CONTENTFUL_API_URL = "https://graphql.contentful.com/content/v1/spaces"
  QUERY = <<~GRAPHQL.freeze
    query {
      events: eventCollection {
        items {
          title
          date
          going
          trackingUrl
        }
      }
    }
  GRAPHQL

  # @return [Array<OpenStruct>]
  def all
    cached = $redis.get(cache_key)
    return wrap(JSON.parse(cached, symbolize_names: true)) if cached.present?

    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    return [] if space.blank? || token.blank?

    response = HTTParty.post(
      "#{CONTENTFUL_API_URL}/#{space}",
      body: { query: QUERY }.to_json,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    )
    return [] unless response.success?

    items = JSON.parse(response.body, symbolize_names: true).dig(:data, :events, :items) || []
    items = items.map { |event| event.deep_transform_keys { |key| key.to_s.underscore.to_sym } }
    $redis.setex(cache_key, 10.minutes, items.to_json)
    wrap(items)
  rescue StandardError => e
    Rails.logger.error("Error fetching events: #{e}")
    []
  end

  private

  def cache_key
    "contentful:events"
  end

  def wrap(items)
    items.map { |event| DeepOstruct.wrap(event) }
  end
end
