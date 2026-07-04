# Resolves Contentful taxonomy concept ids to their names. The GraphQL API exposes only
# concept ids on an entry's contentfulMetadata, so the names/hierarchy live behind the
# delivery taxonomy REST endpoint — fetched once and cached in Redis (the whole vocabulary is
# tiny and changes rarely), then joined against entry concept ids by the consumer.
#
# Delivery API (CDA), same space + token as the GraphQL client. A 404 (taxonomy not enabled)
# or any failure degrades to an empty map, so callers fall back to legacy metadata tags.
class TaxonomyConcepts < ApplicationService
  DELIVERY_API_URL = "https://cdn.contentful.com/spaces"
  CACHE_KEY = "contentful:taxonomy:concepts:v1"
  CACHE_TTL = 1.hour

  # { concept_id => prefLabel } for every concept in the space.
  # @return [Hash{String=>String}]
  def names
    concepts.each_with_object({}) do |concept, map|
      id = concept.dig(:sys, :id)
      name = localized(concept[:prefLabel])
      map[id.to_s] = name if id.present? && name.present?
    end
  end

  private

  # The raw concept items, cached (the block runs only on a cache miss).
  # @return [Array<Hash>]
  def concepts
    cached_json(CACHE_KEY, expires_in: CACHE_TTL) { fetch_concepts } || []
  end

  # Fetches every concept from the delivery taxonomy endpoint, following cursor pages.
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

  # Resolves a localized field (a `{ "en-US" => value }` map on the delivery API) to its
  # single value; passes plain values through.
  def localized(field)
    return field unless field.is_a?(Hash)
    field.values.first
  end
end
