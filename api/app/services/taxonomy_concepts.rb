# Changes each Contentful taxonomy concept id into its name. GraphQL gives only the concept ids on
# an entry, thus the names come from the delivery taxonomy REST endpoint. The code gets them one
# time and caches them, because the set of words is small and it changes rarely. On a failure it
# gives an empty map.
class TaxonomyConcepts < ApplicationService
  DELIVERY_API_URL = "https://cdn.contentful.com/spaces"
  CACHE_KEY = "contentful:taxonomy:concepts:v1"
  CACHE_TTL = 1.hour

  # @return [Hash{String=>String}] Each concept id in the space and its name.
  def names
    concepts.each_with_object({}) do |concept, map|
      id = concept.dig(:sys, :id)
      name = localized(concept[:prefLabel])
      map[id.to_s] = name if id.present? && name.present?
    end
  end

  # The parent of each concept and the scheme that holds it. RelatedArticles uses the parents to
  # give a smaller weight to a match between two concepts that share an ancestor.
  # @return [Hash{String=>Hash}] id => { broader:, scheme: }.
  def tree
    concepts.each_with_object({}) do |concept, map|
      id = concept.dig(:sys, :id).to_s
      next if id.blank?

      map[id] = {
        broader: Array(concept[:broader]).filter_map { |b| b.dig(:sys, :id).presence },
        scheme: Array(concept[:conceptSchemes]).filter_map { |s| s.dig(:sys, :id).presence }.first
      }
    end
  end

  # Each ancestor of one concept, from its parent upward. A cycle in the data cannot make an
  # endless loop, because the code stops at an id that it saw before.
  #
  # ⚠️ The name is not `ancestors`. That name is a method of Module, and Rails and RSpec both call
  # it on a class. To override it broke each of those callers.
  # @param id [String] The concept id.
  # @param tree [Hash] The output of #tree.
  # @return [Array<String>] The ancestor ids.
  def self.ancestor_ids(id, tree)
    seen = []
    # ⚠️ The copy is necessary. Array() gives the same object back for an array, thus shift and
    # concat below changed the tree of the caller. The first article then removed the ancestors
    # for each article after it.
    queue = Array(tree.dig(id.to_s, :broader)).dup

    while (current = queue.shift)
      next if seen.include?(current)
      seen << current
      queue.concat(Array(tree.dig(current, :broader)))
    end

    seen
  end

  private

  # @return [Array<Hash>] The raw concept items, from the cache.
  def concepts
    cached_json(CACHE_KEY, expires_in: CACHE_TTL) { fetch_concepts } || []
  end

  # The most cursor pages to read. The taxonomy is small, and this stops a cursor that names
  # itself.
  MAX_PAGES = 20

  # Gets each concept from the delivery taxonomy endpoint, one cursor page at a time.
  #
  # ⚠️ A page that fails gives nil, and not the pages before it. The caller caches the result for
  # an hour, and a tree with a part absent would score each related list on a different taxonomy
  # for that hour, with no message. `cached_json` does not store nil.
  # @return [Array<Hash>, nil] The items, or nil when a page cannot be read.
  def fetch_concepts
    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    return [] if space.blank? || token.blank?

    headers = { "Authorization" => "Bearer #{token}" }
    url = "#{DELIVERY_API_URL}/#{space}/environments/master/taxonomy/concepts?limit=1000"
    items = []
    MAX_PAGES.times do
      body = get_json(url, headers: headers)
      return nil if body.nil?

      items.concat(Array(body[:items]))
      nxt = body.dig(:pages, :next)
      return items if nxt.blank?

      url = nxt.start_with?("http") ? nxt : "https://cdn.contentful.com#{nxt}"
    end

    report_upstream_error("taxonomy pagination did not end", context: "TaxonomyConcepts pages")
    nil
  end

  # Changes a localized field into its one value. A plain value does not change.
  def localized(field)
    return field unless field.is_a?(Hash)
    field.values.first
  end
end
