require 'active_support/all'
require 'public_suffix'
require 'humanize'
require_relative 'graphql/contentful'
require_relative 'plausible'
require_relative 'google_maps'
require_relative 'weather_kit'
require_relative 'google_air_quality'
require_relative 'google_pollen'

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
    process_analytics
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
      summary = "Browse #{tagged_articles.size.humanize} #{'entry'.pluralize(tagged_articles.size)} tagged ”#{tag[:name]}.”"
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
          template: "/tag.html",
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
    date_ranges = ["all", "30d", "7d", "1d"]

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

  # Processes events and adds weather forecasts for upcoming races within the next 10 days.
  def process_events
    @content[:events].map! do |event|
      process_event_weather(event)
      event[:entry_type] = 'Event'
      event
    end
  end

  # Processes weather data for a single event
  def process_event_weather(event)
    return unless event[:coordinates]&.dig(:lat) && event[:coordinates]&.dig(:lon) && event[:going]

    if ENV['DEBUG_EVENT_WEATHER'].present?
      days = ENV['DEBUG_EVENT_WEATHER'].to_i
      event[:date] = days.days.from_now.to_s
    end

    lat = event[:coordinates][:lat]
    lon = event[:coordinates][:lon]
    event_date = Date.parse(event[:date])
    days_until_event = (event_date - Date.current).to_i

    return unless days_until_event.between?(0, 10)

    # Get location data from Google Maps
    maps = GoogleMaps.new(lat, lon)
    time_zone = maps.time_zone_id
    country_code = maps.country_code
    elevation = maps.location&.dig(:elevation)

    return unless time_zone.present? && country_code.present?

    # Add time zone and elevation to base event
    event[:time_zone] = time_zone
    event[:elevation] = elevation
    event[:country_code] = country_code

    # Get weather forecast
    add_weather_forecast(event)

    # Get AQI data for events in the next 4 days
    add_aqi_data(event) if days_until_event <= 4
  end

  # Adds weather forecast data to an event
  def add_weather_forecast(event)
    event_date = DateTime.parse(event[:date]).in_time_zone(event[:time_zone]).to_date
    lat = event[:coordinates][:lat]
    lon = event[:coordinates][:lon]
    time_zone = event[:time_zone]
    country_code = event[:country_code]

    weather_kit = WeatherKit.new(lat, lon, time_zone, country_code)
    weather_data = weather_kit.weather

    return unless weather_data.present?

    daily_forecast = weather_data.dig(:forecastDaily, :days)

    event_forecast = daily_forecast&.find do |day|
      forecast_date = DateTime.parse(day[:forecastStart]).in_time_zone(event[:time_zone]).to_date rescue nil
      forecast_date == event_date
    end

    return unless event_forecast.present?

    event[:weather] = event_forecast.deep_transform_keys { |k| k.to_s.underscore.to_sym }
  end

  # Adds AQI data to an event
  def add_aqi_data(event)
    lat = event[:coordinates][:lat]
    lon = event[:coordinates][:lon]
    country_code = event[:country_code]
    event_date = DateTime.parse(event[:date]).in_time_zone(event[:time_zone])

    aqi_service = GoogleAirQuality.new(lat, lon, country_code, 'usa_epa_nowcast', event_date)
    aqi_data = aqi_service.aqi

    return unless aqi_data.present?

    event[:weather] ||= {}
    event[:weather][:aqi] = aqi_data[:aqi]
    event[:weather][:aqi_condition] = aqi_data[:category]
    event[:weather][:aqi_description] = aqi_data[:description]
  end
end

