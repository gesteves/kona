require 'graphql/client'
require 'graphql/client/http'
require 'dotenv'
require 'active_support/all'

class Contentful
  Dotenv.load

  HTTP = GraphQL::Client::HTTP.new("https://graphql.contentful.com/content/v1/spaces/#{ENV['CONTENTFUL_SPACE']}") do
    def headers(context)
      { "Authorization": "Bearer #{ENV['CONTENTFUL_TOKEN']}" }
    end
  end

  Schema = GraphQL::Client.load_schema(HTTP)
  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

  QUERIES = Client.parse <<-'GRAPHQL'
    query Content($skip: Int, $limit: Int, $today: DateTime) {
      articles: articleCollection(skip: $skip, limit: $limit, preview: true) {
        items {
          title
          slug
          intro
          body
          author {
            name
          }
          summary
          published
          indexInSearchEngines
          canonicalUrl
          openGraphImage {
            width
            height
            url
            description
          }
          sys {
            id
            firstPublishedAt
            publishedAt
            publishedVersion
          }
          contentfulMetadata {
            tags {
              id
              name
            }
          }
        }
      }
      pages: pageCollection(skip: $skip, limit: $limit, preview: true, order: [title_ASC]) {
        items {
          title
          slug
          body
          summary
          indexInSearchEngines
          canonicalUrl
          isHomePage
          openGraphImage {
            width
            height
            url
            description
          }
          sys {
            id
            firstPublishedAt
            publishedAt
            publishedVersion
          }
        }
      }
      site: siteCollection(limit: 1, order: [sys_firstPublishedAt_ASC]) {
        items {
          title
          metaTitle
          metaDescription
          blurb
          copyright
          email
          entriesPerPage
          author {
            name
            profilePicture {
              width
              height
              url
              description
            }
            location {
              lat
              lon
            }
          }
          navLinksCollection {
            items {
              title
              destination
              openInNewTab
            }
          }
          footerLinksCollection {
            items {
              title
              destination
              openInNewTab
            }
          }
          socialsCollection {
            items {
              title
              destination
              openInNewTab
            }
          }
          logo {
            width
            height
            url
            contentType
          }
          openGraphImage {
            width
            height
            url
            description
          }
          sys {
            publishedAt
          }
        }
      }
      redirects: redirectCollection(skip: $skip, limit: $limit, order: [sys_publishedAt_DESC]) {
        items {
          from
          to
          status
        }
      }
      events: eventCollection(skip: $skip, limit: $limit, where: { date_gte: $today }, order: [date_ASC]) {
        items {
          title
          description
          location
          url
          date
          canceled
          sys {
            id
          }
          contentfulMetadata {
            tags {
              id
              name
            }
          }
        }
      }
      assets: assetCollection(skip: $skip, limit: $limit, preview: true, order: [sys_firstPublishedAt_DESC]) {
        items {
          sys {
            id
          }
          url
          width
          height
          description
          title
          contentType
        }
      }
    }
  GRAPHQL

  def initialize
    @articles = []
    @assets = []
    @events = []
    @pages = []
    @redirects = []
    @site = []
    @blog = []
    @tags = []
    generate_content!
  end

  def save_data
    File.open('data/articles.json', 'w') { |f| f << @articles.to_json }
    File.open('data/blog.json', 'w') { |f| f << @blog.to_json }
    File.open('data/tags.json', 'w') { |f| f << @tags.to_json }
    File.open('data/pages.json', 'w') { |f| f << @pages.to_json }
    File.open('data/site.json', 'w') { |f| f << @site.to_json }
    File.open('data/redirects.json', 'w') { |f| f << @redirects.to_json }
    File.open('data/events.json', 'w') { |f| f << @events.to_json }
    File.open('data/assets.json', 'w') { |f| f << @assets.to_json }
  end

  def location
    @site.dig(:author, :location) || {}
  end

  private

  def generate_content!
    query_contentful!

    @articles.map! do |item|
      set_entry_type(item)
      set_draft_status(item)
      set_timestamps(item)
      set_article_path(item)
      set_template(item)
    end.sort! { |a, b| DateTime.parse(b[:published_at]) <=> DateTime.parse(a[:published_at]) }

    @pages.map! do |item|
      set_entry_type(item, 'Page')
      set_draft_status(item)
      set_timestamps(item)
      set_page_path(item)
      set_template(item)
    end

    generate_blog!(@site[:entriesPerPage])
    generate_tags!(@site[:entriesPerPage])
  end

  def query_contentful!
    puts 'Fetching Contentful data from the API'
    skip = 0
    limit = 1000
    loops = 0
    fetch = true

    while fetch
      response = Client.query(QUERIES::Content, variables: { skip: skip, limit: limit, today: Time.current.in_time_zone(ENV['DEFAULT_TIMEZONE']).beginning_of_day.strftime("%F") })
      loops += 1
      skip = loops * limit

      if response.data.articles.items.blank? && response.data.pages.items.blank? && response.data.assets.items.blank? && response.data.redirects.items.blank? && response.data.events.items.blank?
        fetch = false
      end

      @articles  += response.data.articles.items
      @assets    += response.data.assets.items
      @events    += response.data.events.items
      @pages     += response.data.pages.items
      @redirects += response.data.redirects.items
      @site      += response.data.site.items

      sleep 0.02
    end

    @articles = @articles.compact.map(&:to_h).map(&:with_indifferent_access)
    @pages = @pages.compact.map(&:to_h).map(&:with_indifferent_access)
    @assets = @assets.compact.map(&:to_h).map(&:with_indifferent_access)
    @redirects = @redirects.compact.map(&:to_h).map(&:with_indifferent_access)
    @events = @events.compact.map(&:to_h).map(&:with_indifferent_access)
    @site = @site.compact.map(&:to_h).map(&:with_indifferent_access).first
  end


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

  def set_draft_status(item)
    draft = item.dig(:sys, :publishedVersion).blank?
    item[:draft] = draft
    item[:indexInSearchEngines] = false if draft
    item
  end

  def set_article_path(item)
    item[:path] = if item[:draft]
      "/id/#{item.dig(:sys, :id)}/index.html"
    else
      published = DateTime.parse(item[:published_at])
      "/#{published.strftime('%Y')}/#{published.strftime('%m')}/#{published.strftime('%d')}/#{item[:slug]}/index.html"
    end
    item
  end

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

  def set_timestamps(item)
    item[:published_at] = item.dig(:published) || item.dig(:sys, :firstPublishedAt) || Time.now.to_s
    item[:updated_at] = item.dig(:sys, :publishedAt) || Time.now.to_s
    item
  end

  def generate_tags!(entries_per_page = 10)
    @tags = @articles.map { |a| a.dig(:contentfulMetadata, :tags) }.flatten.uniq
    @tags.map! do |tag|
      tag = tag.dup
      tag[:items] = @articles.select { |a| !a[:draft] && a.dig(:contentfulMetadata, :tags).include?(tag) }
      tag[:path] = "/tagged/#{tag[:id]}/index.html"
      tag[:template] = "/blog.html"
      tag[:title] = tag[:name]
      tag[:indexInSearchEngines] = true
      tag
    end
    @tags.select { |t| t[:items].present? }.sort { |a, b| a[:id] <=> b[:id] }
  end

  def generate_blog!(entries_per_page = 10)
    @blog = []
    sliced = @articles.reject { |a| a[:draft] }.each_slice(entries_per_page)
    sliced.each_with_index do |page, index|
      @blog << {
        current_page: index + 1,
        previous_page: index == 0 ? nil : index,
        next_page: index == sliced.size - 1 ? nil : index + 2,
        template: "/blog.html",
        title: "Blog",
        items: page,
        indexInSearchEngines: true
      }
    end
  end

end
