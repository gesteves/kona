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

  private

  # @return [Array<Hash>] The raw concept items, from the cache.
  def concepts
    cached_json(CACHE_KEY, expires_in: CACHE_TTL) { fetch_concepts } || []
  end

  # Gets each concept from the delivery taxonomy endpoint, one cursor page at a time.
  # @return [Array<Hash>]
  def fetch_concepts
    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    return [] if space.blank? || token.blank?

    headers = { "Authorization" => "Bearer #{token}" }
    url = "#{DELIVERY_API_URL}/#{space}/environments/master/taxonomy/concepts?limit=1000"
    items = []
    loop do
      body = get_json(url, headers: headers)
      break if body.nil?

      items.concat(Array(body[:items]))
      nxt = body.dig(:pages, :next)
      break if nxt.blank?
      url = nxt.start_with?("http") ? nxt : "https://cdn.contentful.com#{nxt}"
    end
    items
  end

  # Changes a localized field into its one value. A plain value does not change.
  def localized(field)
    return field unless field.is_a?(Hash)
    field.values.first
  end
end
