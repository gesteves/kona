# The shared code that keeps a value, for the helper modules. An instance variable of a helper does
# not stay between two Middleman template contexts, and each page has its own. That is why
# memoize_by_collection uses a store at the module level.
module MemoizationHelpers
  class << self
    # @return [Hash] The store at the module level that memoize_by_collection uses.
    def collection_store
      @collection_store ||= {}
    end
  end

  # Keeps a value that comes from a Middleman data collection, for the life of that collection. Thus
  # a data reload on the development server calculates the value again.
  # @param name [Symbol] A name for the value. Each name must be different.
  # @param collection [Object] The collection that the value comes from.
  # @yieldreturn The value.
  def memoize_by_collection(name, collection)
    store = MemoizationHelpers.collection_store
    cached_collection, value = store[name]
    return value if cached_collection.equal?(collection)

    value = yield
    store[name] = [ collection, value ]
    value
  end

  # Keeps the value of one entry in the current template context.
  # @param ivar [Symbol] The instance variable that holds the hash of values.
  # @param key [Object] The cache key. For a blank key, the code calculates the value again and keeps
  #   nothing.
  # @yieldreturn The value.
  def memoize_by_key(ivar, key)
    return yield if key.blank?

    cache = instance_variable_get(ivar) || instance_variable_set(ivar, {})
    cache.key?(key) ? cache[key] : cache[key] = yield
  end
end
