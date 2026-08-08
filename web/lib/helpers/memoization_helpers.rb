# Shared memoization plumbing for the helper modules. Helper instance variables don't survive
# across Middleman's per-page template contexts, which is why memoize_by_collection keeps a
# module-level store instead.
module MemoizationHelpers
  class << self
    # @return [Hash] The module-level store behind memoize_by_collection.
    def collection_store
      @collection_store ||= {}
    end
  end

  # Memoizes a value derived from a Middleman data collection for the life of that collection,
  # so a dev-server data reload recomputes.
  # @param name [Symbol] A unique name for the memoized value.
  # @param collection [Object] The collection the value derives from.
  # @yieldreturn The computed value.
  def memoize_by_collection(name, collection)
    store = MemoizationHelpers.collection_store
    cached_collection, value = store[name]
    return value if cached_collection.equal?(collection)

    value = yield
    store[name] = [ collection, value ]
    value
  end

  # Memoizes a per-entry computation in the current template context.
  # @param ivar [Symbol] The instance variable holding the memo hash.
  # @param key [Object] The cache key; a blank key is computed fresh, uncached.
  # @yieldreturn The computed value.
  def memoize_by_key(ivar, key)
    return yield if key.blank?

    cache = instance_variable_get(ivar) || instance_variable_set(ivar, {})
    cache.key?(key) ? cache[key] : cache[key] = yield
  end
end
