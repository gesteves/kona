require 'active_support/all'
require 'public_suffix'
require 'humanize'
require 'httparty'
require_relative 'graphql/contentful'

class Contentful
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

  # Saves all the content to JSON files.
  def save_data
    @content.each do |type, data|
      save_to_file(type, data)
    end
  end

  private

  # Writes the given data to a JSON file, named after the type of content.
  # @param type [Symbol] The type of content being saved (e.g., :articles, :pages).
  # @param data [Array<Hash>, Hash] The data to be saved into a file.
  def save_to_file(type, data)
    file_path = "data/#{type}.json"
    File.open(file_path, 'w') do |file|
      file << data.to_json
    end
  rescue => e
    puts "Failed to save #{type}: #{e.message}"
  end

  # Generates the content by fetching from Contentful and processing it.
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

  # Fetches all content from Contentful's GraphQL API.
  def get_contentful_data
    skip = 0
    limit = 100
    queries = {
      articles: ContentfulClient::QUERIES::Articles,
      pages: ContentfulClient::QUERIES::Pages,
      assets: ContentfulClient::QUERIES::Assets,
      redirects: ContentfulClient::QUERIES::Redirects,
      events: ContentfulClient::QUERIES::Events,
      sites: ContentfulClient::QUERIES::Sites
    }

    queries.each do |key, query|
      loop do
        response = @client.query(query, variables: { skip: skip, limit: limit })
        raise "Error fetching #{key}: #{response.errors.messages['data'].join(' - ')}" if response.errors.present?

        data = response.data.to_h.deep_transform_keys { |k| k.to_s.underscore.to_sym }
        items = data.dig(key, :items).compact
        @content[key] += items

        break if items.size < limit

        skip += limit
      end
      skip = 0
    end
  end

  # Grabs the first site in the array.
  def process_site
    @content[:site] = @content[:sites].first
    @content.delete(:sites)
  end

  # Processes articles from the fetched content.
  def process_articles
    apply_taxonomy_to_articles
    process_collection(:articles, :set_article_path)
  end

  # Rewrites each article's contentful_metadata[:tags] from its assigned taxonomy concepts,
  # joining concept ids to their name/parent/nested-path via the taxonomy lookup. Falls back
  # to the legacy metadata tags (enriched with a taxonomy path when the concept exists) when
  # an article has no concepts yet or the taxonomy isn't available — so the two-app rollout is
  # safe in either deploy order. The downstream feed/OG/JSON-LD/share helpers keep reading
  # :id/:name unchanged; :path and :parent_id are additive.
  def apply_taxonomy_to_articles
    taxo = taxonomy
    @content[:articles].each do |item|
      cm = (item[:contentful_metadata] ||= {})
      concept_ids = Array(cm[:concepts]).map { |c| c[:id] }.compact

      cm[:tags] = if concept_ids.any? && taxo.any?
        concept_ids.filter_map { |cid| taxo[cid] }.map { |c| c.slice(:id, :name, :short_name, :parent_id, :path) }
      else
        Array(cm[:tags]).map do |t|
          info = taxo[t[:id]]
          { id: t[:id], name: t[:name], short_name: t[:name], parent_id: info&.dig(:parent_id), path: info&.dig(:path) || "/tagged/#{t[:id]}" }
        end
      end
      cm.delete(:concepts)
    end
  end

  # Processes pages from the fetched content.
  def process_pages
    process_collection(:pages, :set_page_path, entry_type: 'Page')
  end

  # The shared shape of the article/page collections: derive the entry fields, set the
  # path via the given setter, and sort newest-first.
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

    # sort_by! parses each date once (vs. twice per comparison with sort!).
    @content[key].sort_by! { |item| DateTime.parse(item[:published_at]) }.reverse!
  end

  # Processes assets from the fetched content.
  def process_assets
    @content[:assets].map! do |item|
      rewrite_image_urls(item)
    end
  end

  # Sets the entry type for a content item based on its attributes.
  # @param item [Hash] The content item to be processed.
  # @param type [String, nil] The specified type to set, if provided.
  # @return [Hash] The item with the entry type set.
  def set_entry_type(item, type = nil)
    item[:entry_type] = if type.present?
      type
    elsif item[:intro].present? && item[:body].present?
      'Article'
    elsif item[:intro].present?
      'Short'
    end
    item
  end

  # Sets the draft status for a content item based on its publication version,
  # and prevents drafts from being indexed by search engines.
  # @param item [Hash] The content item to be processed.
  # @return [Hash] The item with the draft status set.
  def set_draft_status(item)
    draft = item.dig(:sys, :published_version).blank?
    item[:draft] = draft
    item[:index_in_search_engines] = false if draft
    item
  end

  # Sets the published and updated timestamps for a content item.
  # @param item [Hash] The content item to be processed.
  # @return [Hash] The item with timestamps set.
  def set_timestamps(item)
    item[:published_at] = item.dig(:published) || item.dig(:sys, :first_published_at) || Time.now.to_s
    item[:updated_at] = item.dig(:sys, :published_at) || Time.now.to_s
    item
  end

  # The stable id-based preview path drafts live at, regardless of collection.
  # @param item [Hash] The draft item.
  # @return [String] The draft's path.
  def draft_path(item)
    "/id/#{item.dig(:sys, :id)}/index.html"
  end

  # Sets the path for an article based on its draft status and publication date.
  # @param item [Hash] The article to be processed.
  # @return [Hash] The article with the path set.
  def set_article_path(item)
    item[:path] = if item[:draft]
      draft_path(item)
    else
      published = DateTime.parse(item[:published_at])
      "/#{published.strftime('%Y')}/#{published.strftime('%m')}/#{published.strftime('%d')}/#{item[:slug]}/index.html"
    end
    item
  end

  # Sets the path for a page based on its draft status and other attributes.
  # @param item [Hash] The page to be processed.
  # @return [Hash] The page with the path set.
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

  # Sets the Middleman template for a content item based on its entry type and other attributes.
  # @param item [Hash] The content item to be processed.
  # @return [Hash] The item with the template set.
  def set_template(item)
    item[:template] = if item[:entry_type] == 'Article'
      "/article.html"
    elsif item[:entry_type] == 'Short'
      "/short.html"
    elsif item[:entry_type] == 'Page' && item[:is_home_page]
      "/home.html"
    else
      "/page.html"
    end
    item
  end

  # Generates the per-tag archive pages. When the taxonomy is available, pages are built from
  # the concept hierarchy (a page per concept that has articles directly or via its
  # descendants, at its nested `/tagged/<ancestors…>/<id>` path, with the concept's
  # description as the page copy). Otherwise it falls back to the flat, legacy tag behavior.
  def generate_tags
    taxo = taxonomy
    @content[:tags] = taxo.any? ? generate_taxonomy_tags(taxo) : generate_legacy_tags
  end

  # Hierarchy-aware tag pages. Each concept collects its own articles plus all of its
  # descendants' (so e.g. Triathlon lists Ironman 70.3 reports, and the Races parent lists
  # every race report even though it's never assigned directly); concepts with no articles
  # anywhere in their subtree get no page. Article order follows published_articles
  # (newest-first).
  # @return [Array<Hash>]
  def generate_taxonomy_tags(taxo)
    children = Hash.new { |h, k| h[k] = [] }
    taxo.each_value { |c| children[c[:parent_id]] << c[:id] if c[:parent_id] }

    taxo.values.filter_map do |concept|
      id_set = ([concept[:id]] + descendant_ids(concept[:id], children)).to_set
      tagged = published_articles.select do |a|
        Array(a.dig(:contentful_metadata, :tags)).any? { |t| id_set.include?(t[:id]) }
      end
      next if tagged.empty?

      description = concept[:description].presence
      summary = description || default_tag_summary(concept[:name], tagged.size)
      pages = paginate(tagged, base_path: concept[:path], template: "/tag.html",
                       title: concept[:name], summary: summary, description: description)
      { tag: concept.slice(:id, :name, :path, :parent_id, :description), pages: pages }
    end
  end

  # The flat, pre-taxonomy tag pages: one page per unique metadata tag. Used during the
  # transition (before the taxonomy exists) and as a safety net.
  # @return [Array<Hash>]
  def generate_legacy_tags
    tags = published_articles.flat_map { |a| Array(a.dig(:contentful_metadata, :tags)) }.uniq { |t| t[:id] }
    tags.map do |tag|
      tagged_articles = published_articles.select do |a|
        Array(a.dig(:contentful_metadata, :tags)).any? { |t| t[:id] == tag[:id] }
      end
      base_path = tag[:path] || "/tagged/#{tag[:id]}"
      summary = default_tag_summary(tag[:name], tagged_articles.size)
      pages = paginate(tagged_articles, base_path: base_path, template: "/tag.html", title: tag[:name], summary: summary)
      { tag: tag.slice(:id, :name, :path, :parent_id), pages: pages }
    end
  end

  # All descendant concept ids of a concept, walking the children map depth-first.
  # @return [Array<String>]
  def descendant_ids(id, children)
    result = []
    stack = children[id].dup
    until stack.empty?
      cid = stack.pop
      next if result.include?(cid)
      result << cid
      stack.concat(children[cid])
    end
    result
  end

  # The default "Browse N entries tagged X" archive summary, used when a concept has no
  # description (and for every legacy tag).
  def default_tag_summary(name, size)
    "Browse #{size.humanize} #{'entry'.pluralize(size)} tagged “#{name}.”"
  end

  # Generates a paginated collection of blog entries.
  # Each page includes articles for that page, and other metadata.
  # @return [Array<Hash>] A collection of blog pages.
  def generate_blog
    @content[:blog] = paginate(published_articles, base_path: "/blog", template: "/articles.html", title: "Blog")
  end

  # The non-draft articles, in the collection's newest-first order.
  # @return [Array<Hash>]
  def published_articles
    @content[:articles].reject { |a| a[:draft] }
  end

  # Slices a list of articles into pages carrying the pagination metadata the blog/tag
  # templates expect. Page 1 lives at "#{base_path}/index.html", later pages at
  # "#{base_path}/page/N/index.html".
  # @return [Array<Hash>] One hash per page.
  def paginate(articles, base_path:, template:, title:, summary: nil, description: nil)
    sliced = articles.each_slice(@content[:site][:entries_per_page])
    sliced.map.with_index do |page, index|
      current_page = index + 1
      previous_page = index.zero? ? nil : index
      next_page = index == sliced.size - 1 ? nil : index + 2
      page_data = {
        current_page: current_page,
        previous_page: previous_page,
        next_page: next_page,
        template: template,
        path: paginated_path(base_path, current_page),
        previous_page_path: previous_page && paginated_path(base_path, previous_page),
        next_page_path: next_page && paginated_path(base_path, next_page),
        title: title
      }
      page_data[:summary] = summary if summary
      page_data[:description] = description if description
      page_data[:items] = page
      page_data[:index_in_search_engines] = true
      page_data
    end
  end

  # The path for one page of a paginated collection.
  def paginated_path(base_path, page_number)
    page_number == 1 ? "#{base_path}/index.html" : "#{base_path}/page/#{page_number}/index.html"
  end

  # Rewrites Contentful image URLs to CloudFront URLs.
  # @param item [Hash] The asset to be processed.
  # @return [Hash] The asset with the image URLs rewritten.
  def rewrite_image_urls(item)
    return item if ENV['CLOUDFRONT_DOMAIN'].blank?
    uri = URI.parse(item[:url])
    version = item.dig(:sys, :published_version)
    domain = PublicSuffix.domain(uri.host)

    if domain == 'ctfassets.net'
      uri.host = ENV['CLOUDFRONT_DOMAIN']
      if version.present?
        uri.query = uri.query.to_s.empty? ? "v=#{version}" : "#{uri.query}&v=#{version}"
      end
      item[:url] = uri.to_s
    end
    item
  rescue => e
    puts "Error rewriting image URL: #{e.message}"
    item
  end

  # The taxonomy concepts, keyed by id, memoized for the build. GraphQL only returns concept
  # ids on entries, so names/hierarchy/descriptions are joined from the delivery taxonomy REST
  # endpoint here. Each value: { id:, name:, parent_id:, path:, description:, synonyms: }.
  # Empty when the taxonomy isn't available yet (callers fall back to legacy tags).
  # @return [Hash{String=>Hash}]
  def taxonomy
    @taxonomy ||= build_taxonomy
  end

  # Builds the taxonomy lookup from the fetched concepts: resolves localized labels, reads each
  # concept's parent from its first `broader` link, and derives the nested `/tagged/...` path.
  def build_taxonomy
    concepts = fetch_taxonomy_concepts
    by_id = {}
    concepts.each do |c|
      id = c.dig('sys', 'id')
      next if id.blank?
      name = localized(c['prefLabel'])
      synonyms = Array(localized(c['altLabels']))
      by_id[id] = {
        id: id,
        name: name,
        short_name: shortest_label(name, synonyms),
        parent_id: Array(c['broader']).first&.dig('sys', 'id'),
        description: localized(c['definition']),
        synonyms: synonyms
      }
    end
    by_id.each_value { |c| c[:path] = concept_path(c[:id], by_id) }
    by_id
  end

  # The most compact label for a concept's chip: the shortest of its name and its synonyms
  # (altLabels), preferring the name on ties. So adding a short altLabel like "Coeur d'Alene"
  # to "Ironman 70.3 Coeur d'Alene" shows the short one in chips, while the full name is still
  # used for the archive title, breadcrumb, and JSON-LD keywords.
  def shortest_label(name, synonyms)
    ([name].compact + Array(synonyms)).reject(&:blank?).min_by(&:length) || name
  end

  # Fetches every concept from the delivery taxonomy endpoint (CPA host + preview token, same
  # credentials as the GraphQL client). Cursor-paginated via `pages.next`. A 404 means the
  # taxonomy isn't enabled yet — we warn and fall back to legacy tags rather than break the
  # build; any other non-2xx raises (matching the GraphQL error handling).
  # @return [Array<Hash>] raw concept hashes (string keys, localized fields as locale maps).
  def fetch_taxonomy_concepts
    space = ENV['CONTENTFUL_SPACE']
    token = ENV['CONTENTFUL_TOKEN']
    return [] if space.blank? || token.blank?

    url = "https://preview.contentful.com/spaces/#{space}/environments/master/taxonomy/concepts?limit=1000"
    headers = { 'Authorization' => "Bearer #{token}" }
    items = []
    loop do
      response = HTTParty.get(url, headers: headers)
      if response.code == 404
        warn '[taxonomy] delivery concepts endpoint returned 404 — taxonomy not available yet; falling back to legacy tags'
        return []
      end
      raise "Error fetching taxonomy concepts: #{response.code} #{response.body}" unless response.code.between?(200, 299)

      body = response.parsed_response
      items.concat(Array(body['items']))
      nxt = body.dig('pages', 'next')
      break if nxt.blank?
      # `pages.next` is a full URL on the delivery API; guard in case it's ever a path.
      url = nxt.start_with?('http') ? nxt : "https://preview.contentful.com#{nxt}"
    end
    items
  end

  # Resolves a localized concept field (a `{ 'en-US' => value }` map on the delivery API) to
  # its single value. Passes through plain strings/arrays and nil.
  def localized(field)
    return field unless field.is_a?(Hash)
    field.values.first
  end

  # The nested archive path for a concept: `/tagged/<root…>/<id>`, following parent links up
  # to the root (a root concept is just `/tagged/<id>`). Guards against cycles.
  def concept_path(id, by_id)
    chain = []
    cur = id
    seen = {}
    while cur && by_id[cur] && !seen[cur]
      seen[cur] = true
      chain.unshift(cur)
      cur = by_id[cur][:parent_id]
    end
    "/tagged/#{chain.join('/')}"
  end

  # Processes events and adds weather forecasts for upcoming races within the next 10 days.
  def process_events
    @content[:events].map! do |event|
      if ENV['DEBUG_EVENT_DATE'].present?
        days = ENV['DEBUG_EVENT_DATE'].to_i
        event[:date] = days.days.from_now.to_s
      end

      event[:entry_type] = 'Event'
      event
    end
  end
end

