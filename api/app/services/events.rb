# Fetches race events from Contentful. `all` pulls the full set of fields the upcoming-races
# widget renders (title/summary/description/location/url/date/going/coordinates), which is a
# superset of what the current-weather widget needs to spot today's race. Cached in Redis for
# 10 minutes. `all` returns an array wrapped for dot-access.
class Events < ApplicationService
  include ContentfulConsumer

  QUERY = <<~GRAPHQL.freeze
    query($skip: Int, $limit: Int) {
      events: eventCollection(skip: $skip, limit: $limit) {
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
    find_cached_item(id, query: FIND_QUERY, collection: :events,
                         cache_key: "contentful:event", context: "Error fetching event #{id}")
  end

  # @return [Array<OpenStruct>]
  def all
    items = rescue_with([], context: "Error fetching events") do
      # The key's suffix is a digest of the query, so changing its field set invalidates the
      # cache on its own — a value cached under an older shape would be missing fields the views
      # read. Cached for 5 minutes: the edge cache is the primary freshness layer, and this just
      # guards Contentful against a stampede.
      cached_json("contentful:events:#{cache_version(QUERY)}", expires_in: 5.minutes) do
        # Paginated and strict: an unpaginated query silently caps at Contentful's default page,
        # and a partial corpus here drops races from the widget rather than failing visibly.
        (contentful.paginate(QUERY, collection: :events, strict: true) || []).map { |event| underscore_keys(event) }
      end
    end

    wrap(items || [])
  end

  private

  def wrap(items)
    items.map { |event| DeepOstruct.wrap(event) }
  end
end
