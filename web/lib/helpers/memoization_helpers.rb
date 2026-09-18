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

  # Keeps a value that comes from one or more Middleman data collections, for the life of those
  # collections. Thus a data reload on the development server calculates the value again.
  # @param name [Symbol] A name for the value. Each name must be different.
  # @param collections [Array<Object>] The collections that the value comes from. A new object at
  #   any one of them makes the value again.
  # @yieldreturn The value.
  def memoize_by_collection(name, *collections)
    store = MemoizationHelpers.collection_store
    if store.key?(name)
      cached_collections, value = store[name]
      return value if cached_collections.size == collections.size &&
                      cached_collections.zip(collections).all? { |cached, given| cached.equal?(given) }
    end

    value = yield
    store[name] = [ collections, value ]
    value
  end

  # Keeps the value of one entry, in a store by collection. Thus one value serves each page that
  # renders the entry, and a data reload makes it again.
  # @param name [Symbol] A name for the store. Each name must be different.
  # @param key [Object] The key of the entry. For a blank key, the code calculates the value again
  #   and keeps nothing.
  # @param collections [Array<Object>] The collections that the value comes from.
  # @yieldreturn The value.
  def memoize_entry(name, key, *collections)
    return yield if key.blank?

    store = memoize_by_collection(name, *collections) { {} }
    return store[key] if store.key?(key)

    store[key] = yield
  end
end
