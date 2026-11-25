# The taxonomy of an entry: the chain of concepts from a tag to its root, the breadcrumbs, and
# the tag links of the meta line. `data.tags` holds the concepts.
module TaxonomyHelpers
  # The chain of parents of the most deeply nested concept of an article, in the two schemes. If
  # two concepts are at the same depth, the number of articles in the archive of the concept
  # selects one.
  # @return [Array<Hash>] The [{ id:, name:, path: }] items, the root first, or [] if the article
  #   has no tags.
  def taxonomy_trail(content)
    tags = Array(content.contentful_metadata&.tags)
    return [] if tags.empty?

    index = taxonomy_index
    chains = tags.map { |t| concept_chain(t.id) }.reject(&:empty?)
    return [] if chains.empty?

    chains.max_by { |chain| [ chain.length, index.dig(chain.last[:id], :count).to_i ] }
  end

  # The chain of parents of a concept id, from data.tags. It starts at the root and includes the
  # concept.
  # @return [Array<Hash>] [{ id:, name:, path: }], or [] if the id is not a known concept.
  def concept_chain(id)
    index = taxonomy_index
    chain = []
    cur = id
    seen = {}
    while cur && (node = index[cur]) && !seen[cur]
      seen[cur] = true
      chain.unshift({ id: cur, name: node[:name], path: node[:path] })
      cur = node[:parent_id]
    end
    chain
  end

  # Concept id => { name:, path:, parent_id:, scheme:, count: }, from the tag pages that the
  # build makes. Each parent has a page, thus each chain is always complete.
  # @return [Hash{String=>Hash}]
  def taxonomy_index
    memoize_by_collection(:taxonomy_index, data.tags) do
      Array(data.tags).each_with_object({}) do |entry, index|
        tag = entry.tag
        # Refer to Contentful#generate_tags for the reason for the name entry_count.
        index[tag.id] = { name: tag.name, path: tag.path, parent_id: tag.parent_id, scheme: tag.scheme, count: tag.entry_count }
      end
    end
  end

  # The separator between the tag links in a breadcrumb chain.
  TAG_SEPARATOR = '<span class="entry__tag-separator" aria-hidden="true">/</span>'.freeze

  # The tag icon for a tag list: one tag gets the "tag" icon, more than one gets "tags".
  # @param count [Integer] The number of tags in the list.
  # @return [String, nil] The icon SVG.
  def tag_list_icon(count)
    icon_svg("classic", "light", count == 1 ? "tag" : "tags")
  end

  # Renders a list of tag links, that is, [label, path] pairs. Each link is a role="listitem"
  # span, and a slash goes between the spans. The article meta line and the tag-archive header
  # both use this.
  # @param links [Array<Array(String, String)>] The [label, path] pairs.
  # @return [String] The markup, joined.
  def tag_chain_links(links)
    links.map { |label, path| content_tag(:span, link_to(label, path), role: "listitem") }.join(TAG_SEPARATOR)
  end

  # The concepts of the article for the meta line: the breadcrumb chains as one flat list, with
  # each concept one time. Two chains that share a parent give that parent one time, and the
  # children of that parent stay together.
  # @return [Array<Object>] The tags, a parent before its children.
  def tag_breadcrumb_concepts(article)
    flatten_concept_chains(tag_breadcrumb_chains(article))
  end

  private

  # The concepts of the article as breadcrumb chains, one chain for each leaf concept. The code
  # reads each chain through the full taxonomy, then keeps only the concepts that the article
  # has. Thus it removes a concept in the middle that the article does not have, and the chain
  # stays complete. The most deeply nested chain is first, and Sports goes before Topics at the
  # same depth.
  # @return [Array<Array>] One array of tags for each chain, from the root to the leaf.
  def tag_breadcrumb_chains(article)
    tags = Array(article.contentful_metadata&.tags)
    return [] if tags.empty?

    by_id = tags.to_h { |t| [ t.id, t ] }
    chain_ids = tags.to_h { |t| [ t.id, concept_chain(t.id).map { |n| n[:id] } ] }
    ancestor_ids = chain_ids.values.flat_map { |ids| ids[0...-1] }.to_set
    leaves = tags.reject { |t| ancestor_ids.include?(t.id) }

    # ⚠️ Reject the empty chains. A concept with no published article gets no tag page, thus it is
    # absent from the taxonomy and `concept_chain` gives []. A draft can hold such a concept.
    chains = leaves.map { |leaf| chain_ids[leaf.id].filter_map { |id| by_id[id] } }.reject(&:empty?)
    chains.sort_by { |chain| [ -chain.length, chain.first.scheme == "sports" ? 0 : 1, chain.last.short_name.to_s ] }
  end

  # Walks the chains as a tree and gives the concepts at one depth and below, a parent before its
  # children. A concept that more than one chain holds goes into the list one time.
  # @param chains [Array<Array>] The chains, from the root to the leaf.
  # @param depth [Integer] The position in a chain to group on.
  # @return [Array<Object>] The tags.
  def flatten_concept_chains(chains, depth = 0)
    chains.reject { |chain| chain.length <= depth }
          .group_by { |chain| chain[depth].id }
          .flat_map { |_id, group| [ group.first[depth] ] + flatten_concept_chains(group, depth + 1) }
  end
end
