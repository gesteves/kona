require "active_support/all"
require "humanize"
require "httparty"
require_relative "graphql/contentful"

class Contentful
  # Raised when IMAGE_HOST is unset. The zone allowlists only the R2 mirror as a Cloudflare
  # Images source, so there is no working URL to emit without it.
  class ImageHostMissing < StandardError
    MESSAGE = <<~MSG.freeze
      IMAGE_HOST is unset, so asset URLs would still point at Contentful.

      It's the bare hostname of the R2 bucket the api mirrors Contentful's image assets into,
      and the only host allowlisted as a Cloudflare Images transformation source — so leaving
      it unset doesn't fall back to Contentful, it 403s every image on the site. Set it in .env
      locally and in the build env for deploys.

      Don't allowlist *.ctfassets.net to work around this: that renders perfectly while draining
      Contentful's metered asset bandwidth, which is the drain the mirror exists to stop.
    MSG

    def initialize(message = MESSAGE) = super
  end

  def initialize
    @client = ContentfulClient::Client
    @content = {
      articles: [],
      assets: [],
      events: [],
      pages: [],
      redirects: [],
      sites: [],
      blog: [],
      tags: []
    }

    generate_content!
  end

  # Writes every fetched collection to data/*.json.
  def save_data
    @content.each do |type, data|
      save_to_file(type, data)
    end
  end

  private

  # Writes one collection to data/<type>.json.
  #
  # ⚠️ Deliberately unrescued. `rake clobber` deletes data/*.json, so a swallowed write failure
  # leaves the file missing while the import still reports success — and the build then renders
  # pages against data that isn't there. Fail loudly, like import:icons does.
  # @param type [Symbol] The collection's name.
  # @param data [Array<Hash>, Hash] The data to write.
  def save_to_file(type, data)
    File.write("data/#{type}.json", data.to_json)
  end

  # Fetches everything from Contentful and derives the collections the build reads.
  def generate_content!
    get_contentful_data
    process_site
    process_articles
    process_pages
    process_assets
    process_events
    generate_blog
    generate_tags
  end

  # Fetches every collection from Contentful's GraphQL API, paginating each one.
  # @return [Hash{Symbol => Object}] The paginated collections to fetch, by data key.
  def collection_queries
    {
      articles: ContentfulClient::QUERIES::Articles,
      pages: ContentfulClient::QUERIES::Pages,
      assets: ContentfulClient::QUERIES::Assets,
      redirects: ContentfulClient::QUERIES::Redirects,
      events: ContentfulClient::QUERIES::Events,
      sites: ContentfulClient::QUERIES::Sites
    }
  end

  # Pages within a collection have to be sequential (each `skip` depends on the last page), but
  # the collections don't depend on each other, so they're fetched concurrently. A raise in any
  # thread surfaces on the join and still fails the import.
  def get_contentful_data
    collection_queries
      .map { |key, query| Thread.new { [ key, fetch_collection(key, query) ] } }
      .each { |thread| key, items = thread.value; @content[key] += items }
  end

  # Pages through one collection.
  # @param key [Symbol] The collection's data key.
  # @param query [Object] The GraphQL query.
  # @return [Array<Hash>] Every item in it.
  def fetch_collection(key, query)
    limit = 100
    skip = 0
    items = []

    loop do
      response = @client.query(query, variables: { skip: skip, limit: limit })
      raise "Error fetching #{key}: #{response.errors.messages['data'].join(' - ')}" if response.errors.present?

      data = response.data.to_h.deep_transform_keys { |k| k.to_s.underscore.to_sym }
      page = data.dig(key, :items) || []
      items += page.compact

      # ⚠️ The page's raw size decides whether there's another page, not the compacted one.
      # Contentful returns a null item for any link it can't resolve, so comparing after
      # `compact` ends pagination early and silently truncates the collection.
      break if page.size < limit

      skip += limit
    end

    items
  end

  # Collapses the sites collection to the single site entry.
  def process_site
    @content[:site] = @content[:sites].first
    @content.delete(:sites)
  end

  # Derives each article's taxonomy, entry fields, and path.
  def process_articles
    apply_taxonomy_to_articles
    process_collection(:articles, :set_article_path)
  end

  # Rewrites each article's contentful_metadata[:tags] from its assigned concept ids, joining
  # them to their name, short name, scheme, parent, path, and synonyms.
  def apply_taxonomy_to_articles
    taxo = taxonomy
    @content[:articles].each do |item|
      cm = (item[:contentful_metadata] ||= {})
      concept_ids = Array(cm[:concepts]).map { |c| c[:id] }.compact
      cm[:tags] = concept_ids.filter_map { |cid| taxo[cid] }.map { |c| c.slice(:id, :name, :short_name, :scheme, :parent_id, :path, :synonyms) }
      cm.delete(:concepts)
    end
  end

  # Derives each page's entry fields and path.
  def process_pages
    process_collection(:pages, :set_page_path, entry_type: "Page")
  end

  # Derives the entry fields for a collection, sets each item's path, and sorts newest-first.
  # @param key [Symbol] The @content collection to process.
  # @param path_setter [Symbol] The method that sets each item's :path.
  # @param entry_type [String, nil] A fixed entry type, or nil to derive it per item.
  def process_collection(key, path_setter, entry_type: nil)
    @content[key].map! do |item|
      set_entry_type(item, entry_type)
      set_draft_status(item)
      set_timestamps(item)
      send(path_setter, item)
      set_template(item)
    end

    # sort_by! parses each date once, where sort! would parse twice per comparison.
    @content[key].sort_by! { |item| DateTime.parse(item[:published_at]) }.reverse!
  end

  # Points every asset URL at the image mirror.
  def process_assets
    @content[:assets].map! do |item|
      rewrite_image_urls(item)
    end
  end

  # Points an asset's URL at IMAGE_HOST, the R2 bucket the api mirrors published assets into,
  # so Cloudflare Images fetches the untransformed source from inside our own zone.
  #
  # Cross-app contract: only the host changes, so Contentful's path is the R2 key. The api
  # writes objects under exactly this path, neither side validates the other, and a mismatch
  # 404s every image on the site silently. Setting IMAGE_HOST also asserts the mirror is
  # populated — run the api's `rake assets:backfill` first. See the root CLAUDE.md.
  # @param item [Hash] The asset to rewrite.
  # @return [Hash] The asset.
  # @raise [ImageHostMissing] if IMAGE_HOST is unset.
  def rewrite_image_urls(item)
    raise ImageHostMissing if ENV["IMAGE_HOST"].blank?

    uri = URI.parse(item[:url])
    # Every ctfassets host, not just images.ctfassets.net: Contentful serves some image assets
    # from downloads.ctfassets.net, and matching only the images host would leave those hitting
    # Contentful forever. Paths are identical across hosts, so one key covers both. The api's
    # AssetMirror#object_key must keep matching the same set.
    if uri.host.to_s.end_with?(".ctfassets.net")
      uri.host = ENV["IMAGE_HOST"]
      item[:url] = uri.to_s
    end
    item
  rescue ImageHostMissing
    # A misconfigured build must fail; the rescue below only covers one asset's malformed URL.
    raise
  rescue => e
    puts "Error rewriting image URL: #{e.message}"
    item
  end

  # Sets an item's entry type: the given one, else Article or Short depending on whether it has
  # a body.
  # @param item [Hash] The item to process.
  # @param type [String, nil] A fixed type.
  # @return [Hash] The item.
  def set_entry_type(item, type = nil)
    item[:entry_type] = if type.present?
      type
    elsif item[:intro].present? && item[:body].present?
      "Article"
    elsif item[:intro].present?
      "Short"
    end
    item
  end

  # Marks an item a draft when it has no published version, and unindexable when it's a draft.
  # @param item [Hash] The item to process.
  # @return [Hash] The item.
  def set_draft_status(item)
    draft = item.dig(:sys, :published_version).blank?
    item[:draft] = draft
    item[:index_in_search_engines] = false if draft
    item
  end

  # Sets an item's published and updated timestamps.
  # @param item [Hash] The item to process.
  # @return [Hash] The item.
  def set_timestamps(item)
    item[:published_at] = item.dig(:published) || item.dig(:sys, :first_published_at) || Time.now.to_s
    item[:updated_at] = item.dig(:sys, :published_at) || Time.now.to_s
    item
  end

  # @param item [Hash] A draft item.
  # @return [String] The stable id-based preview path drafts live at.
  def draft_path(item)
    "/id/#{item.dig(:sys, :id)}/index.html"
  end

  # Sets an article's path: its draft preview path, or its dated permalink.
  # @param item [Hash] The article to process.
  # @return [Hash] The article.
  def set_article_path(item)
    item[:path] = if item[:draft]
      draft_path(item)
    else
      # Y/M/D come from the timestamp's own zone, never normalized to UTC: published permalinks
      # must not move, and the local date is the one the entry was published under.
      published = DateTime.parse(item[:published_at])
      "/#{published.strftime('%Y')}/#{published.strftime('%m')}/#{published.strftime('%d')}/#{item[:slug]}/index.html"
    end
    item
  end

  # Sets a page's path: its draft preview path, the site root, or its slug.
  # @param item [Hash] The page to process.
  # @return [Hash] The page.
  def set_page_path(item)
    item[:path] = if item[:draft]
      draft_path(item)
    elsif item[:is_home_page]
      "/index.html"
    else
      "/#{item[:slug]}/index.html"
    end
    item
  end

  # Sets the Middleman template an item renders through.
  # @param item [Hash] The item to process.
  # @return [Hash] The item.
  def set_template(item)
    item[:template] = if item[:entry_type] == "Article"
      "/article.html"
    elsif item[:entry_type] == "Short"
      "/short.html"
    elsif item[:entry_type] == "Page" && item[:is_home_page]
      "/home.html"
    else
      "/page.html"
    end
    item
  end

  # Builds the per-tag archive pages: one per concept with articles in its own subtree, so a
  # parent lists everything its descendants are tagged with. Concepts with an empty subtree get
  # no page.
  def generate_tags
    taxo = taxonomy
    children = Hash.new { |h, k| h[k] = [] }
    taxo.each_value { |c| children[c[:parent_id]] << c[:id] if c[:parent_id] }

    # Hoisted: published_articles rebuilds the array on every call, and this loop runs once per
    # concept. The set is fixed for the whole loop.
    candidates = published_articles

    @content[:tags] = taxo.values.filter_map do |concept|
      id_set = ([ concept[:id] ] + descendant_ids(concept[:id], children)).to_set
      tagged = candidates.select do |a|
        Array(a.dig(:contentful_metadata, :tags)).any? { |t| id_set.include?(t[:id]) }
      end
      next if tagged.empty?

      description = concept[:description].presence
      summary = description || default_tag_summary(concept[:name], tagged.size)
      # The page renders this as "Updated", and sitemap.xml derives lastmod from the same field,
      # so it tracks the newest edit — not the newest publish.
      updated_at = tagged.filter_map { |a| a[:updated_at] || a[:published_at] }.max
      # `path` carries a trailing slash; listing_page wants the bare base.
      pages = listing_page(tagged, base_path: concept[:path].chomp("/"), template: "/tag.html",
                           title: concept[:name], summary: summary, description: description,
                           updated_at: updated_at, tag_id: concept[:id])
      # entry_count, not count: `count` collides with Hash#count on the Hashie::Mash.
      { tag: concept.slice(:id, :name, :path, :scheme, :parent_id, :description, :synonyms).merge(entry_count: tagged.size), pages: pages }
    end
  end

  # @return [Array<String>] Every descendant concept id, walked depth-first.
  def descendant_ids(id, children)
    result = []
    # Set, not Array#include?, which made the walk quadratic in the subtree size.
    seen = Set.new
    stack = children[id].dup
    until stack.empty?
      cid = stack.pop
      next unless seen.add?(cid)
      result << cid
      stack.concat(children[cid])
    end
    result
  end

  # The archive summary used when a concept has no description of its own.
  def default_tag_summary(name, size)
    "Browse #{size.humanize} #{'entry'.pluralize(size)} tagged “#{name}.”"
  end

  # The blog index's own meta description. Without it `content_summary` falls all the way
  # through to the sitewide meta description, so /blog and the home page ship identical ones.
  # Only `summary:` is set, not `description:` — articles.html.erb renders no description block,
  # so this is a meta tag and nothing else.
  def default_blog_summary(size)
    "Browse the complete archive of #{size.humanize} #{'entry'.pluralize(size)}, newest first."
  end

  # Builds the blog index listing: every published entry, newest first.
  # @return [Array<Hash>] The blog's listing page.
  def generate_blog
    entries = published_articles
    @content[:blog] = listing_page(entries, base_path: "/blog", template: "/articles.html",
                                   title: "Blog", summary: default_blog_summary(entries.size))
  end

  # @return [Array<Hash>] The non-draft articles, newest first.
  def published_articles
    @content[:articles].reject { |a| a[:draft] }
  end

  # Builds the listing page for a collection of articles. Returned as a one-element array
  # because the page proxies in config.rb iterate over a collection.
  # @return [Array<Hash>] One listing page.
  def listing_page(articles, base_path:, template:, title:, summary: nil, description: nil, updated_at: nil, tag_id: nil)
    page_data = {
      template: template,
      path: "#{base_path}/index.html",
      title: title
    }
    page_data[:summary] = summary if summary
    page_data[:description] = description if description
    # Tag-archive metadata; nil for the blog index.
    page_data[:tag_id] = tag_id if tag_id
    page_data[:updated_at] = updated_at if updated_at
    page_data[:items] = articles
    page_data[:index_in_search_engines] = true
    [ page_data ]
  end

  # The taxonomy concepts keyed by id, memoized for the build. GraphQL returns only concept ids
  # on entries, so the rest is joined from the delivery taxonomy REST endpoint.
  # @return [Hash{String=>Hash}]
  def taxonomy
    @taxonomy ||= build_taxonomy
  end

  # Builds the taxonomy lookup: resolves localized labels, reads each concept's parent from its
  # first `broader` link, and derives its nested archive path.
  def build_taxonomy
    concepts = fetch_taxonomy_concepts
    by_id = {}
    concepts.each do |c|
      id = c.dig("sys", "id")
      next if id.blank?
      name = localized(c["prefLabel"])
      synonyms = Array(localized(c["altLabels"]))
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

  # The most compact label for a concept's chip: the shortest of its name and synonyms,
  # preferring the name on ties. The full name is still used for titles and breadcrumbs.
  def shortest_label(name, synonyms)
    ([ name ].compact + Array(synonyms)).reject(&:blank?).min_by(&:length) || name
  end

  # Fetches every concept from the delivery taxonomy endpoint, cursor-paginated. Concepts are
  # the sole source of article categorization, so a non-2xx fails the build.
  # @return [Array<Hash>] Raw concept hashes, with localized fields as locale maps.
  def fetch_taxonomy_concepts
    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    # ⚠️ Raise, don't return []: concepts are the only source of categorization, so an empty
    # taxonomy is a *successful* build with no tag pages, no breadcrumbs and no article:tag
    # metadata — the same silent-misconfiguration failure ImageHostMissing exists to prevent.
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
      # A full URL on the delivery API; guarded in case it's ever a path.
      url = nxt.start_with?("http") ? nxt : "https://preview.contentful.com#{nxt}"
    end
    items
  end

  # Resolves a localized concept field to its single value, passing through plain values.
  def localized(field)
    return field unless field.is_a?(Hash)
    field.values.first
  end

  # The nested archive URL for a concept, following parent links to the root. The trailing
  # slash matches the built directory-index page, so links don't redirect. Cycle-safe.
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

  # Tags events with their entry type, honoring DEBUG_EVENT_DATE to shift an event's date.
  def process_events
    @content[:events].map! do |event|
      if ENV["DEBUG_EVENT_DATE"].present?
        days = Integer(ENV["DEBUG_EVENT_DATE"])
        event[:date] = days.days.from_now.to_s
      end

      event[:entry_type] = "Event"
      event
    end
  end
end
