# The shared code of the services that read from Contentful: a client that the code keeps, and the
# common shape of a cached query that finds one entry by its id.
module ContentfulConsumer
  private

  def contentful
    @contentful ||= ContentfulClient.new(self.class.name)
  end

  # Gets one item by its entry id, through the read-through cache, in an object with dot access.
  # @param id [String, nil] The Contentful entry id.
  # @param query [String] A GraphQL query that takes an `$id` variable.
  # @param collection [Symbol] The key of the collection in the response.
  # @param cache_key [String] The start of the Redis key. The id goes at the end.
  # @param context [String] The context for an error report.
  # @param empty_expires_in [ActiveSupport::Duration] The time that the cache holds a miss.
  #   ⚠️ This is necessary: rack-attack does not apply to /widgets/*, a visitor can reach those paths
  #   through the proxy of the site, and the code checks only the format of the id. Thus without
  #   this value, an unknown id costs one Contentful query for each request, for all time. The time
  #   is short, thus a new entry appears quickly.
  # @return [OpenStruct, nil] The item, or nil on an error.
  def find_cached_item(id, query:, collection:, cache_key:, context:, expires_in: 5.minutes, empty_expires_in: 1.minute)
    return if id.blank?

    item = rescue_with(context: context) do
      cached_json("#{cache_key}:#{id}", expires_in: expires_in, empty_expires_in: empty_expires_in) do
        underscore_keys(contentful.items(query, { id: id }, collection: collection)&.first)
      end
    end

    item && DeepOstruct.wrap(item)
  end
end
