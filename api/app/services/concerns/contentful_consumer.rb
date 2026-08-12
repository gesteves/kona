# Shared plumbing for the services that read from Contentful: a memoized client plus the common
# cached find-by-entry-id query shape.
module ContentfulConsumer
  private

  def contentful
    @contentful ||= ContentfulClient.new(self.class.name)
  end

  # Fetches one item by entry id through the read-through cache, wrapped for dot-access.
  # @param id [String, nil] The Contentful entry id.
  # @param query [String] A GraphQL query taking an `$id` variable.
  # @param collection [Symbol] The collection key in the response.
  # @param cache_key [String] The Redis key prefix; the id is appended.
  # @param context [String] The error-report context.
  # @param empty_expires_in [ActiveSupport::Duration] How long a miss is remembered. ⚠️ Load-bearing:
  #   /widgets/* is exempt from rack-attack and reachable through the site's proxy, and the id is
  #   only format-checked, so without this an unknown id costs a Contentful query per request,
  #   forever. Kept short so a newly published entry isn't masked for long.
  # @return [OpenStruct, nil] The item, or nil on error.
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
