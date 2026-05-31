# Fetches race events from Contentful with a small, targeted GraphQL query — just the
# fields the weather widget needs to spot today's race (title, date, going, trackingUrl).
# Cached in Redis for 10 minutes. `all` returns an array wrapped for dot-access.
class Events < ApplicationService
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

  FIND_QUERY = <<~GRAPHQL.freeze
    query($id: String!) {
      events: eventCollection(where: { sys: { id: $id } }, limit: 1) {
        items {
          title
          date
          location
          coordinates { lat lon }
          sys { id }
        }
      }
    }
  GRAPHQL

  # Fetches a single event by its Contentful entry ID (with coordinates), for the
  # per-event weather endpoint. Cached in Redis for an hour.
  # @return [OpenStruct, nil]
  def find(id)
    return if id.blank?

    item = rescue_with(context: "Error fetching event #{id}") do
      cached_json("contentful:event:#{id}", expires_in: 1.hour) do
        underscore_keys(query_events(FIND_QUERY, { id: id })&.first)
      end
    end

    item && DeepOstruct.wrap(item)
  end

  # @return [Array<OpenStruct>]
  def all
    items = rescue_with([], context: "Error fetching events") do
      cached_json("contentful:events", expires_in: 10.minutes) do
        (query_events(QUERY) || []).map { |event| underscore_keys(event) }
      end
    end

    wrap(items || [])
  end

  private

  # Runs a Contentful GraphQL query and returns its `events.items`, or nil when the API
  # isn't configured or the request fails.
  def query_events(query, variables = nil)
    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    return if space.blank? || token.blank?

    body = { query: query }
    body[:variables] = variables if variables.present?

    data = post_json(
      "#{CONTENTFUL_API_URL}/#{space}",
      body: body.to_json,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    )
    data&.dig(:data, :events, :items)
  end

  def wrap(items)
    items.map { |event| DeepOstruct.wrap(event) }
  end
end
