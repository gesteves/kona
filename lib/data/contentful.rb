require 'active_support/all'
require_relative 'graphql/contentful'
require_relative 'plausible'
require_relative '../helpers/markdown_helpers'
require_relative '../helpers/text_helpers'

class Contentful
  include MarkdownHelpers
  include TextHelpers

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
    process_analytics
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
    @content[:articles].map! do |item|
      set_entry_type(item)
      set_draft_status(item)
      set_timestamps(item)
      set_article_path(item)
      set_template(item)
      set_reading_time(item)
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

  # Calculates the reading time for an article based on its word count.
  # @param item [Hash] The article to be processed.
  # @param wpm [Integer] (Optional) The average words per minute for reading. Default is 200.
  # @return [Hash] The article with the reading time set.
  def set_reading_time(item, wpm: 200)
    plain_text = sanitize([item[:intro], item[:body]].reject(&:blank?).join("\n\n"), escape_html_entities: true)
    word_count = plain_text.split(/\s+/).size
    item[:reading_time_minutes] = (word_count / wpm.to_f).ceil
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
      summary = "Browse all #{tagged_articles.any? { |a| a[:entry_type] == 'Short'} ? 'articles and posts' : 'articles' } tagged ”#{tag[:name]}”."
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
          summary: summary,
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

  # Fetches traffic data from Plausible for articles,
  # and stores it in each article.
  def process_analytics
    # Define the metrics to query
    metrics = ["pageviews", "visits", "visitors"]

    # Define the date ranges to process
    date_ranges = ["all", "1d"]

    # Initialize a hash to store analytics data for each date range
    analytics_by_range = {}

    date_ranges.each do |date_range|
      # Query analytics for the current date range
      analytics = Plausible.new.query(metrics: metrics, date_range: date_range, filters: [["matches", "event:page", ["^/20\\d{2}/"]]])

      # Create a lookup hash for quick access to analytics data by path
      analytics_by_range[date_range] = (analytics.dig(:results) || []).each_with_object({}) do |result, hash|
        path = result[:dimensions].first.sub(/\/index\.html$/, '/') # Normalize the path
        hash[path] = metrics.zip(result[:metrics]).to_h # Create a hash of metric names and values
      end
    end

    # Add analytics data to each article under :metrics for each date range, defaulting metrics to 0
    @content[:articles].each do |article|
      normalized_path = article[:path].sub(/\/index\.html$/, '/') # Normalize the article path
      article[:metrics] ||= {} # Initialize the metrics key if it doesn't exist

      date_ranges.each do |date_range|
        article[:metrics][date_range.to_sym] = metrics.each_with_object({}) do |metric, hash|
          hash[metric] = analytics_by_range[date_range].dig(normalized_path, metric) || 0 # Default to 0 if missing
        end
      end
    end
  end
end
