require "active_support/all"
require "humanize"
require "httparty"
require_relative "graphql/contentful"

class Contentful
  # The app raises this when IMAGE_HOST has no value. The zone permits only the R2 mirror as a
  # Cloudflare Images source, thus there is no correct URL to write without it.
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

  # Writes each collection that it gets to data/*.json.
  def save_data
    @content.each do |type, data|
      save_to_file(type, data)
    end
  end

  private

  # Writes one collection to data/<type>.json.
  #
  # ⚠️ There is no rescue here, on purpose. `rake clobber` deletes data/*.json. Thus a write
  # failure that a rescue hides leaves the file absent while the import reports success, and the
  # build then renders pages with data that does not exist. Fail with a message, as import:icons
  # does.
  # @param type [Symbol] The name of the collection.
  # @param data [Array<Hash>, Hash] The data to write.
  def save_to_file(type, data)
    File.write("data/#{type}.json", data.to_json)
  end

  # Gets all the data from Contentful and makes the collections that the build reads.
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

  # Gets each collection from the Contentful GraphQL API, one page at a time.
  # @return [Hash{Symbol => Object}] The collections to get, by data key.
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

  # The pages in one collection must come in sequence, because each `skip` depends on the last
  # page. But the collections do not depend on each other, thus the code gets them at the same
  # time. A raise in a thread comes back at the join and still stops the import.
  def get_contentful_data
    collection_queries
      .map { |key, query| Thread.new { [ key, fetch_collection(key, query) ] } }
      .each { |thread| key, items = thread.value; @content[key] += items }
  end

  # Reads one collection, one page at a time.
  # @param key [Symbol] The data key of the collection.
  # @param query [Object] The GraphQL query.
  # @return [Array<Hash>] All the items in it.
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

      # ⚠️ The raw size of the page tells if there is another page. Do not use the size after
      # `compact`. Contentful returns a null item for each link that it cannot resolve. Thus a
      # comparison after `compact` stops the pages too soon and makes the collection incomplete.
      break if page.size < limit

      skip += limit
    end

    items
  end

  # Makes the sites collection into the one site entry.
  def process_site
    @content[:site] = @content[:sites].first
    @content.delete(:sites)
  end

  # Makes the taxonomy, the entry fields, and the path of each article.
  def process_articles
    apply_taxonomy_to_articles
    process_collection(:articles, :set_article_path)
  end

  # Changes the contentful_metadata[:tags] of each article from its concept ids. It joins each id
  # to its name, short name, scheme, parent, path, and synonyms.
  def apply_taxonomy_to_articles
    taxo = taxonomy
    @content[:articles].each do |item|
      cm = (item[:contentful_metadata] ||= {})
      concept_ids = Array(cm[:concepts]).map { |c| c[:id] }.compact
      cm[:tags] = concept_ids.filter_map { |cid| taxo[cid] }.map { |c| c.slice(:id, :name, :short_name, :scheme, :parent_id, :path, :synonyms) }
      cm.delete(:concepts)
    end
  end

  # Makes the entry fields and the path of each page.
  def process_pages
    process_collection(:pages, :set_page_path, entry_type: "Page")
  end

  # Makes the entry fields for a collection, sets the path of each item, and puts the newest item
  # first.
  # @param key [Symbol] The @content collection to change.
  # @param path_setter [Symbol] The method that sets the :path of each item.
  # @param entry_type [String, nil] A fixed entry type, or nil to make one for each item.
  def process_collection(key, path_setter, entry_type: nil)
    @content[key].map! do |item|
      set_entry_type(item, entry_type)
      set_draft_status(item)
      set_timestamps(item)
      send(path_setter, item)
      set_template(item)
    end

    # sort_by! parses each date one time. sort! would parse two dates for each comparison.
    @content[key].sort_by! { |item| DateTime.parse(item[:published_at]) }.reverse!
  end

  # Sets each asset URL to the image mirror.
  def process_assets
    @content[:assets].map! do |item|
      rewrite_image_urls(item)
    end
  end

  # Sets the URL of an asset to IMAGE_HOST, the R2 bucket that the api copies published assets
  # into. Thus Cloudflare Images gets the source with no transformation from inside our own zone.
  #
  # This is a contract between the two apps: only the host changes, thus the Contentful path is
  # the R2 key. The api writes each object at this same path. Neither side checks the other, and
  # a difference makes each image on the site 404 with no message. A value in IMAGE_HOST also
  # says that the mirror is complete. Run the `rake assets:backfill` of the api first. Refer to
  # the root CLAUDE.md.
  # @param item [Hash] The asset to change.
  # @return [Hash] The asset.
  # @raise [ImageHostMissing] If IMAGE_HOST has no value.
  def rewrite_image_urls(item)
    raise ImageHostMissing if ENV["IMAGE_HOST"].blank?

    uri = URI.parse(item[:url])
    # Match each ctfassets host, not only images.ctfassets.net. Contentful serves some image
    # assets from downloads.ctfassets.net. If you match only the images host, those assets go to
    # Contentful for all time. The paths are the same on both hosts, thus one key is sufficient
    # for both. The AssetMirror#object_key of the api must match the same set.
    if uri.host.to_s.end_with?(".ctfassets.net")
      uri.host = ENV["IMAGE_HOST"]
      item[:url] = uri.to_s
    end
    item
  rescue ImageHostMissing
    # A build with an incorrect configuration must fail. The rescue below is only for one asset
    # with an incorrect URL.
    raise
  rescue => e
    puts "Error rewriting image URL: #{e.message}"
    item
  end

  # Sets the entry type of an item: the given type, or Article if the item has a body and Short
  # if it does not.
  # @param item [Hash] The item to change.
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

  # Marks an item as a draft if it has no published version. A draft also gets a mark that stops
  # a search engine from an index of it.
  # @param item [Hash] The item to change.
  # @return [Hash] The item.
  def set_draft_status(item)
    draft = item.dig(:sys, :published_version).blank?
    item[:draft] = draft
    item[:index_in_search_engines] = false if draft
    item
  end

  # Sets the published and updated timestamps of an item.
  # @param item [Hash] The item to change.
  # @return [Hash] The item.
  def set_timestamps(item)
    item[:published_at] = item.dig(:published) || item.dig(:sys, :first_published_at) || Time.now.to_s
    item[:updated_at] = item.dig(:sys, :published_at) || Time.now.to_s
    item
  end

  # @param item [Hash] A draft item.
  # @return [String] The stable preview path of a draft, which comes from its id.
  def draft_path(item)
    "/id/#{item.dig(:sys, :id)}/index.html"
  end

  # Sets the path of an article: its draft preview path, or its permalink with the date.
  # @param item [Hash] The article to change.
  # @return [Hash] The article.
  def set_article_path(item)
    item[:path] = if item[:draft]
      draft_path(item)
    else
      # The year, month, and day come from the zone of the timestamp. Never change them to UTC.
      # A published permalink must not move, and the local date is the publish date of the entry.
      published = DateTime.parse(item[:published_at])
      "/#{published.strftime('%Y')}/#{published.strftime('%m')}/#{published.strftime('%d')}/#{item[:slug]}/index.html"
    end
    item
  end

  # Sets the path of a page: its draft preview path, the site root, or its slug.
  # @param item [Hash] The page to change.
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

  # Sets the Middleman template that renders an item.
  # @param item [Hash] The item to change.
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

  # Makes the archive page for each tag: one page for each concept that has articles in its own
  # subtree. Thus a parent lists each article that its children have a tag for. A concept with an
  # empty subtree gets no page.
  def generate_tags
    taxo = taxonomy
    children = Hash.new { |h, k| h[k] = [] }
    taxo.each_value { |c| children[c[:parent_id]] << c[:id] if c[:parent_id] }

    # This is outside the loop, because published_articles makes the array again at each call and
    # this loop runs one time for each concept. The set does not change in the loop.
    candidates = published_articles

    @content[:tags] = taxo.values.filter_map do |concept|
      id_set = ([ concept[:id] ] + descendant_ids(concept[:id], children)).to_set
      tagged = candidates.select do |a|
        Array(a.dig(:contentful_metadata, :tags)).any? { |t| id_set.include?(t[:id]) }
      end
      next if tagged.empty?

      description = concept[:description].presence
      summary = description || default_tag_summary(concept[:name], tagged.size)
      # The publish date of the newest entry in the archive. The page renders it. ⚠️ Do not use
      # `updated_at` here: sitemap.xml makes lastmod from the most recent *edit* of an entry, and
      # the page shows the most recent *publish*.
      published_at = tagged.filter_map { |a| a[:published_at] }.max_by { |d| DateTime.parse(d) }
      # `path` has a slash at the end. listing_page needs the base with no slash.
      pages = listing_page(tagged, base_path: concept[:path].chomp("/"), template: "/tag.html",
                           title: concept[:name], summary: summary, description: description,
                           published_at: published_at, tag_id: concept[:id])
      # Use entry_count, not count: `count` is Hash#count on the Hashie::Mash.
      { tag: concept.slice(:id, :name, :path, :scheme, :parent_id, :description, :synonyms).merge(entry_count: tagged.size), pages: pages }
    end
  end

  # @return [Array<String>] All the child concept ids, in depth-first order.
  def descendant_ids(id, children)
    result = []
    # Use a Set, not Array#include?. Array#include? made this much slower on a large subtree.
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

  # The archive summary for a concept that has no description of its own.
  def default_tag_summary(name, size)
    "Browse #{size.humanize} #{'entry'.pluralize(size)} tagged “#{name}.”"
  end

  # The meta description of the blog index. Without it, `content_summary` goes to the sitewide
  # meta description, and /blog and the home page then have the same one. This sets only
  # `summary:`, not `description:`, because articles.html.erb renders no description block. Thus
  # this is a meta tag and nothing more.
  def default_blog_summary(size)
    "Browse the complete archive of #{size.humanize} #{'entry'.pluralize(size)}, newest first."
  end

  # Makes the list for the blog index: each published entry, the newest first.
  # @return [Array<Hash>] The blog's listing page.
  def generate_blog
    entries = published_articles
    @content[:blog] = listing_page(entries, base_path: "/blog", template: "/articles.html",
                                   title: "Blog", summary: default_blog_summary(entries.size))
  end

  # @return [Array<Hash>] The non-draft articles, the newest first.
  def published_articles
    @content[:articles].reject { |a| a[:draft] }
  end

  # Makes the listing page for a collection of articles. It returns an array with one item,
  # because the page proxies in config.rb read a collection.
  # @return [Array<Hash>] One listing page.
  def listing_page(articles, base_path:, template:, title:, summary: nil, description: nil, published_at: nil, tag_id: nil)
    page_data = {
      template: template,
      path: "#{base_path}/index.html",
      title: title
    }
    page_data[:summary] = summary if summary
    page_data[:description] = description if description
    # The metadata of the tag archive. It is nil for the blog index.
    page_data[:tag_id] = tag_id if tag_id
    page_data[:published_at] = published_at if published_at
    page_data[:items] = articles
    page_data[:index_in_search_engines] = true
    [ page_data ]
  end

  # The taxonomy concepts by id. The app keeps the value for the build. GraphQL gives only the
  # concept ids on an entry, thus the delivery taxonomy REST endpoint supplies the other fields.
  # @return [Hash{String=>Hash}]
  def taxonomy
    @taxonomy ||= build_taxonomy
  end

  # Makes the taxonomy lookup: it finds the localized labels, reads the parent of each concept
  # from its first `broader` link, and makes its nested archive path.
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

  # The shortest label for the chip of a concept: the shortest of its name and its synonyms. If
  # two are the same length, it uses the name. The titles and the breadcrumbs use the full name.
  def shortest_label(name, synonyms)
    ([ name ].compact + Array(synonyms)).reject(&:blank?).min_by(&:length) || name
  end

  # Gets each concept from the delivery taxonomy endpoint, one page at a time with a cursor. The
  # concepts are the only source of the categories of an article, thus a non-2xx stops the build.
  # @return [Array<Hash>] The raw concept hashes. Each localized field is a locale map.
  def fetch_taxonomy_concepts
    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    # ⚠️ Raise here, do not return []. The concepts are the only source of the categories. Thus
    # an empty taxonomy gives a *successful* build with no tag pages, no breadcrumbs, and no
    # article:tag metadata. This is the same failure with no message that ImageHostMissing stops.
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
      # This is a full URL on the delivery API. The check is for a path, if it becomes one.
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

  # Gives each event its entry type. DEBUG_EVENT_DATE can move the date of an event.
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
