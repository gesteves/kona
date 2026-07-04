# Shared memoization plumbing for the helper modules, in two flavors:
#
# - memoize_by_collection: build-level memos for values derived from a Middleman data
#   collection. Helper instance variables don't survive across Middleman's per-page template
#   contexts, so these live in a module-level store keyed by the collection's identity — a
#   dev-server data reload produces a new collection object and recomputes.
# - memoize_by_key: per-context memos for expensive per-entry computations (keyed by e.g.
#   an entry's sys.id), recomputing without caching when the key is blank.
module MemoizationHelpers
  class << self
    # The module-level store behind memoize_by_collection.
    # @return [Hash]
    def collection_store
      @collection_store ||= {}
    end
  end

  # @param name [Symbol] A unique name for the memoized value.
  # @param collection [Object] The data collection the value derives from.
  # @yieldreturn The computed value.
  def memoize_by_collection(name, collection)
    store = MemoizationHelpers.collection_store
    cached_collection, value = store[name]
    return value if cached_collection.equal?(collection)

    value = yield
    store[name] = [collection, value]
    value
  end

  # @param ivar [Symbol] The instance variable holding the memo hash (e.g. :@word_counts).
  # @param key [Object] The cache key; a blank key is computed fresh, uncached.
  # @yieldreturn The computed value.
  def memoize_by_key(ivar, key)
    return yield if key.blank?

    cache = instance_variable_get(ivar) || instance_variable_set(ivar, {})
    cache.key?(key) ? cache[key] : cache[key] = yield
  end
end
