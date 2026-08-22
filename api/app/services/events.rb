# Gets the race events from Contentful. `all` gets each field that the upcoming-races widget
# renders: title, summary, description, location, url, date, going, and coordinates. That set
# includes each field that the current-weather widget needs to find the race of today. Redis caches
# it for 10 minutes. `all` returns an array in an object with dot access.
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

  # Gets one event by its Contentful entry ID, with its coordinates, for the weather endpoint of
  # that event. Redis caches it for 5 minutes.
  # @return [OpenStruct, nil]
  def find(id)
    find_cached_item(id, query: FIND_QUERY, collection: :events,
                         cache_key: "contentful:event", context: "Error fetching event #{id}")
  end

  # @return [Array<OpenStruct>]
  def all
    items = rescue_with([], context: "Error fetching events") do
      # The end of the key is a digest of the query. Thus a change to its fields makes a new key by
      # itself. A value in the cache with an older shape would have no value for a field that a view
      # reads. The cache holds it for 5 minutes: the edge cache is the main layer for freshness, and
      # this cache only stops many requests to Contentful at one time.
      cached_json("contentful:events:#{cache_version(QUERY)}", expires_in: 5.minutes) do
        # This reads one page at a time and it is strict. A query with no pages stops at the default
        # page size of Contentful, with no message, and an incomplete set here removes races from
        # the widget and gives no error.
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
