# Shared plumbing for services that read from Contentful (Articles, Events, StandardSite):
# a memoized ContentfulClient plus the common "cached find-by-entry-id" query shape.
module ContentfulConsumer
  private

  def contentful
    @contentful ||= ContentfulClient.new(self.class.name)
  end

  # Fetches a single item by Contentful entry id through the read-through Redis cache,
  # wrapped for dot-access. Errors are reported and return nil (via rescue_with).
  # @param id [String, nil] The Contentful entry id.
  # @param query [String] The GraphQL query (taking an `$id` variable).
  # @param collection [Symbol] The collection key in the query's response.
  # @param cache_key [String] The Redis key prefix; the id is appended.
  # @param context [String] Error-report context.
  # @return [OpenStruct, nil]
  def find_cached_item(id, query:, collection:, cache_key:, context:, expires_in: 5.minutes)
    return if id.blank?

    item = rescue_with(context: context) do
      cached_json("#{cache_key}:#{id}", expires_in: expires_in) do
        underscore_keys(contentful.items(query, { id: id }, collection: collection)&.first)
      end
    end

    item && DeepOstruct.wrap(item)
  end
end
