require 'active_support/all'
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
      site: [],
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
    generate_blog
    generate_tags
  end

  # Fetches all content from Contentful's GraphQL API.
  def get_contentful_data
    skip = 0
    limit = 100
    loop do
      # Fetch the data from the API.
      response = @client.query(ContentfulClient::QUERIES::Content, variables: { skip: skip, limit: limit })
      raise if response.data.blank?
      # Convert the data in the response to a hash, and transform the keys from camelCase to Ruby-style camel_case :symbols.
      data = response.data.to_h.deep_transform_keys { |key| key.to_s.underscore.to_sym }
      # Break the loop when the API stops returning items for all of the content types.
      break if data.keys.all? { |k| data.dig(k, :items).empty? }
      # Add them to the @content instance variable.
      [:articles, :pages, :assets, :redirects, :events, :site].each { |c| @content[c] += data.dig(c, :items).compact }
      skip += limit
    end
  end

  # Grabs the first site in the array.
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

  # Generates a collection of unique tags from articles.
  # Each tag includes a paginated collection of articles with that tag, and other metadata.
  # @return [Array<Hash>] A collection of tag pages.
  def generate_tags
    entries_per_page = @content[:site][:entries_per_page]
    tags = @content[:articles].reject { |a| a[:draft] }.map { |a| a.dig(:contentful_metadata, :tags) }.flatten.uniq
    paginated_tags = tags.map do |tag|
      tag = tag.dup
      tagged_articles = @content[:articles].select { |a| !a[:draft] && a.dig(:contentful_metadata, :tags).include?(tag) }
      sliced = tagged_articles.each_slice(entries_per_page)
      paginated_tag_pages = sliced.map.with_index do |page, index|
        current_page = index + 1
        previous_page = index.zero? ? nil : index
        next_page = index == sliced.size - 1 ? nil : index + 2
        path = current_page == 1 ? "/tagged/#{tag[:id]}/index.html" : "/tagged/#{tag[:id]}/page/#{current_page}/index.html"
        previous_page_path = if previous_page.blank?
          nil
        elsif previous_page == 1
          "/tagged/#{tag[:id]}/index.html"
        else
          "/tagged/#{tag[:id]}/page/#{previous_page}/index.html"
        end
        next_page_path = if next_page.blank?
          nil
        else
          "/tagged/#{tag[:id]}/page/#{next_page}/index.html"
        end

        {
          current_page: current_page,
          previous_page: previous_page,
          next_page: next_page,
          template: "/articles.html",
          path: path,
          previous_page_path: previous_page_path,
          next_page_path: next_page_path,
          title: tag[:name],
          items: page,
          index_in_search_engines: true
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
    entries_per_page = @content[:site][:entries_per_page]
    sliced_articles = @content[:articles].reject { |a| a[:draft] }.each_slice(entries_per_page)
    blog_pages = sliced_articles.map.with_index do |page, index|
      current_page = index + 1
      previous_page = index.zero? ? nil : index
      next_page = index == sliced_articles.size - 1 ? nil : index + 2
      path = current_page == 1 ? "/blog/index.html" : "/blog/page/#{current_page}/index.html"
      previous_page_path = if previous_page.blank?
        nil
      elsif previous_page == 1
        "/blog/index.html"
      else
        "/blog/page/#{previous_page}/index.html"
      end
      next_page_path = if next_page.blank?
        nil
      else
        "/blog/page/#{next_page}/index.html"
      end
      {
        current_page: current_page,
        previous_page: previous_page,
        next_page: next_page,
        template: "/articles.html",
        path: path,
        previous_page_path: previous_page_path,
        next_page_path: next_page_path,
        title: "Blog",
        items: page,
        index_in_search_engines: true
      }
    end
    @content[:blog] = blog_pages
  end
end
