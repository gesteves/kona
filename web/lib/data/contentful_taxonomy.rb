require "active_support/all"
require "httparty"

# The taxonomy concepts of the space. GraphQL gives only the concept ids on an entry, thus the
# taxonomy endpoint of the Preview API gives the other fields.
class ContentfulTaxonomy
  # Makes the lookup: it finds the localized labels, reads the parent of each concept from its
  # first `broader` link, and makes its nested archive path.
  # @return [Hash{String=>Hash}] Each concept by id.
  def concepts
    by_id = {}
    fetch_concepts.each do |c|
      id = c.dig("sys", "id")
      next if id.blank?
      name = localized(c["prefLabel"])
      synonyms = Array(localized(c["altLabels"]))
      # ⚠️ The archive tree follows the FIRST parent only. A concept with two parents is absent
      # from the archive of the second one, with no message but this line.
      if Array(c["broader"]).size > 1
        warn "Taxonomy: the concept #{name.inspect} (#{id}) has #{Array(c['broader']).size} parents; the archive follows the first one only."
      end
      by_id[id] = {
        id: id,
        name: name,
        short_name: shortest_label(name, synonyms),
        scheme: Array(c["conceptSchemes"]).first&.dig("sys", "id"),
        parent_id: Array(c["broader"]).first&.dig("sys", "id"),
        description: localized(c["definition"]),
        synonyms: synonyms
      }
    end
    by_id.each_value { |c| c[:path] = concept_path(c[:id], by_id) }
    by_id
  end

  private

  # The shortest label for the chip of a concept: the shortest of its name and its synonyms. If
  # two are the same length, it uses the name. The titles and the breadcrumbs use the full name.
  def shortest_label(name, synonyms)
    ([ name ].compact + Array(synonyms)).reject(&:blank?).min_by(&:length) || name
  end

  # Gets each concept from the taxonomy endpoint of the Preview API, one page at a time with a
  # cursor. The concepts are the only source of the categories of an article, thus a non-2xx stops
  # the build.
  # @return [Array<Hash>] The raw concept hashes. Each localized field is a locale map.
  def fetch_concepts
    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    # ⚠️ Raise here, do not return []. An empty taxonomy gives a *successful* build with no tag
    # pages, no breadcrumbs, and no article:tag metadata.
    raise "CONTENTFUL_SPACE and CONTENTFUL_TOKEN are required to fetch the taxonomy." if space.blank? || token.blank?

    url = "https://preview.contentful.com/spaces/#{space}/environments/master/taxonomy/concepts?limit=1000"
    headers = { "Authorization" => "Bearer #{token}" }
    items = []
    loop do
      response = HTTParty.get(url, headers: headers)
      raise "Error fetching taxonomy concepts: #{response.code} #{response.body}" unless response.code.between?(200, 299)

      body = response.parsed_response
      items.concat(Array(body["items"]))
      nxt = body.dig("pages", "next")
      break if nxt.blank?
      # This is a full URL on the Preview API. The check is for a path, if it becomes one.
      url = nxt.start_with?("http") ? nxt : "https://preview.contentful.com#{nxt}"
    end
    items
  end

  # Changes a localized concept field into its one value. A plain value does not change.
  def localized(field)
    return field unless field.is_a?(Hash)
    field.values.first
  end

  # The nested archive URL for a concept. It follows the parent links to the root. The slash at
  # the end agrees with the directory-index page that the build makes, thus a link does not
  # redirect. A cycle in the links cannot stop it.
  def concept_path(id, by_id)
    chain = []
    cur = id
    seen = {}
    while cur && by_id[cur] && !seen[cur]
      seen[cur] = true
      chain.unshift(cur)
      cur = by_id[cur][:parent_id]
    end
    "/tagged/#{chain.join('/')}/"
  end
end
