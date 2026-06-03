# Fetches race events from Contentful. `all` pulls the full set of fields the upcoming-races
# widget renders (title/summary/description/location/url/date/going/coordinates), which is a
# superset of what the current-weather widget needs to spot today's race. Cached in Redis for
# 10 minutes. `all` returns an array wrapped for dot-access.
class Events < ApplicationService
  CONTENTFUL_API_URL = "https://graphql.contentful.com/content/v1/spaces"
  QUERY = <<~GRAPHQL.freeze
    query {
      events: eventCollection {
        items {
          title
          summary
          description
          location
          url
          trackingUrl
          date
          going
          coordinates { lat lon }
          sys { id }
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
  # per-event weather endpoint. Cached in Redis for 5 minutes.
  # @return [OpenStruct, nil]
  def find(id)
    return if id.blank?

    item = rescue_with(context: "Error fetching event #{id}") do
      cached_json("contentful:event:#{id}", expires_in: 5.minutes) do
        underscore_keys(query_events(FIND_QUERY, { id: id })&.first)
      end
    end

    item && DeepOstruct.wrap(item)
  end

  # @return [Array<OpenStruct>]
  def all
    items = rescue_with([], context: "Error fetching events") do
      # Cache key carries a version suffix: the query's field set changed (the upcoming-races
      # widget needs more than the old today's-race lookup), so a value cached under the old
      # key would be missing fields. Cached for 5 minutes — the edge cache is the primary
      # freshness layer; this just guards Contentful against a stampede.
      cached_json("contentful:events:v3", expires_in: nil) do
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
