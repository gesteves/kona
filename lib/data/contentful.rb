require 'active_support/all'
require 'redis'
require_relative 'graphql/contentful'

class Contentful
  CACHE_KEY = "contentful:content:v1"
  CACHE_EXPIRATION = 300

  def initialize
    @client = ContentfulClient::Client
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
    @content = {
      articles: [],
      assets: [],
      events: [],
      pages: [],
      redirects: [],
      site: [],
      blog: [],
      tags: []
    }

    generate_content!
  end

  def save_data
    @content.each do |type, data|
      save_to_file(type, data)
    end
  end

  def location
    @content[:site].dig(:author, :location) || {}
  end

  private

  def save_to_file(type, data)
    file_path = "data/#{type}.json"
    File.open(file_path, 'w') do |file|
      file << data.to_json
    end
  rescue => e
    puts "Failed to save #{type}: #{e.message}"
  end

  def generate_content!
    content = @redis.get(CACHE_KEY)
    if content
      @content = JSON.parse(content, symbolize_names: true)
    else
      fetch_all_content
      process_site
      process_articles
      process_pages
      generate_blog
      generate_tags
      cache_content
    end
  end

  def fetch_all_content
    skip = 0
    limit = 100
    loop do
      response = @client.query(ContentfulClient::QUERIES::Content, variables: { skip: skip, limit: limit })
      break if response.data.articles.items.empty? && response.data.pages.items.empty? &&
               response.data.assets.items.empty? && response.data.redirects.items.empty? &&
               response.data.events.items.empty?

      process_fetched_data(response)
      skip += limit
    end
  end

  # Processes and stores the fetched data from each API call.
  # @param response [GraphQL::Client::Response] The response from the GraphQL query.
  def process_fetched_data(response)
    @content[:articles] += response.data.articles.items.compact.map(&:to_h).map(&:with_indifferent_access)
    @content[:pages] += response.data.pages.items.compact.map(&:to_h).map(&:with_indifferent_access)
    @content[:assets] += response.data.assets.items.compact.map(&:to_h).map(&:with_indifferent_access)
    @content[:redirects] += response.data.redirects.items.compact.map(&:to_h).map(&:with_indifferent_access)
    @content[:events] += response.data.events.items.compact.map(&:to_h).map(&:with_indifferent_access)
    @content[:site] += response.data.site.items.compact.map(&:to_h).map(&:with_indifferent_access)
  end

  # Ensures there's only one `site` stored (that should be the case, but just in case).
  def process_site
    @content[:site] = @content[:site].first
  end

  # Processes articles from the fetched content.
  def process_articles
    @content[:articles].map! do |item|
      set_entry_type(item)
      set_draft_status(item)
      set_timestamps(item)
      set_article_path(item)
      set_template(item)
    end

    @content[:articles].sort! { |a, b| DateTime.parse(b[:published_at]) <=> DateTime.parse(a[:published_at]) }
  end

  # Processes pages from the fetched content.
  def process_pages
    @content[:pages].map! do |item|
      set_entry_type(item, 'Page')
      set_draft_status(item)
      set_timestamps(item)
      set_page_path(item)
      set_template(item)
    end

    @content[:pages].sort! { |a, b| DateTime.parse(b[:published_at]) <=> DateTime.parse(a[:published_at]) }
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
    draft = item.dig(:sys, :publishedVersion).blank?
    item[:draft] = draft
    item[:indexInSearchEngines] = false if draft
    item
  end

  # Sets the published and updated timestamps for a content item.
  # @param item [Hash] The content item to be processed.
  # @return [Hash] The item with timestamps set.
  def set_timestamps(item)
    item[:published_at] = item.dig(:published) || item.dig(:sys, :firstPublishedAt) || Time.now.to_s
    item[:updated_at] = item.dig(:sys, :publishedAt) || Time.now.to_s
    item
  end

  # Sets the path for an article based on its draft status and publication date.
  # @param item [Hash] The article to be processed.
  # @return [Hash] The article with the path set.
  def set_article_path(item)
    item[:path] = if item[:draft]
      "/id/#{item.dig(:sys, :id)}/index.html"
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
      "/id/#{item.dig(:sys, :id)}/index.html"
    elsif item[:isHomePage]
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
    elsif item[:entry_type] == 'Page' && item[:isHomePage]
      "/home.html"
    else
      "/page.html"
    end
    item
  end

  # Generates a collection of unique tags from articles.
  # Each tag includes a paginated collection of articles with that tag, and other metadata.
  # @return [Array<Hash>] A collection of tag pages.
  def generate_tags
    entries_per_page = @content[:site][:entriesPerPage]
    tags = @content[:articles].reject { |a| a[:draft] }.map { |a| a.dig(:contentfulMetadata, :tags) }.flatten.uniq
    paginated_tags = tags.map do |tag|
      tag = tag.dup
      tagged_articles = @content[:articles].select { |a| !a[:draft] && a.dig(:contentfulMetadata, :tags).include?(tag) }
      sliced = tagged_articles.each_slice(entries_per_page)
      paginated_tag_pages = sliced.map.with_index do |page, index|
        current_page = index + 1
        previous_page = index.zero? ? nil : index
        next_page = index == sliced.size - 1 ? nil : index + 2
        {
          current_page: current_page,
          previous_page: previous_page,
          next_page: next_page,
          template: "/articles.html",
          path: current_page == 1 ? "/tagged/#{tag[:id]}/index.html" : "/tagged/#{tag[:id]}/page/#{current_page}/index.html",
          title: tag[:name],
          items: page,
          indexInSearchEngines: true
        }
      end
      { tag: tag, pages: paginated_tag_pages }
    end
    @content[:tags] = paginated_tags
  end

  # Generates a paginated collection of blog entries.
  # Each page includes articles for that page, and other metadata.
  # @return [Array<Hash>] A collection of blog pages.
  def generate_blog
    entries_per_page = @content[:site][:entriesPerPage]
    sliced_articles = @content[:articles].reject { |a| a[:draft] }.each_slice(entries_per_page)
    blog_pages = sliced_articles.map.with_index do |page, index|
      current_page = index + 1
      previous_page = index.zero? ? nil : index
      next_page = index == sliced_articles.size - 1 ? nil : index + 2
      {
        current_page: current_page,
        previous_page: previous_page,
        next_page: next_page,
        template: "/articles.html",
        path: current_page == 1 ? "/blog/index.html" : "/blog/page/#{current_page}/index.html",
        title: "Blog",
        items: page,
        indexInSearchEngines: true
      }
    end
    @content[:blog] = blog_pages
  end

  def cache_content
    @redis.setex(CACHE_KEY, CACHE_EXPIRATION, @content.to_json)
  end
end
