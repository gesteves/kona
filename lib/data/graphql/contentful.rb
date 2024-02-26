require 'graphql/client'
require 'graphql/client/http'
require 'dotenv'

module ContentfulClient
  Dotenv.load

  # Creates the HTTP client for GraphQL
  HTTP = GraphQL::Client::HTTP.new("https://graphql.contentful.com/content/v1/spaces/#{ENV['CONTENTFUL_SPACE']}") do
    def headers(context)
      { "Authorization": "Bearer #{ENV['CONTENTFUL_TOKEN']}" }
    end
  end

  # Load the GraphQL schema
  Schema = GraphQL::Client.load_schema(HTTP)

  # Create the GraphQL client
  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

  QUERIES = Client.parse <<-'GRAPHQL'
    query Content ($skip: Int, $limit: Int) {
      articles: articleCollection(skip: $skip, limit: $limit, preview: true) {
        items {
          title
          slug
          intro
          body
          author {
            slug
            name
          }
          summary
          published
          indexInSearchEngines
          canonicalUrl
          coverImage {
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
          coverImage {
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
      site: siteCollection(skip: $skip, limit: 1, order: [sys_firstPublishedAt_ASC]) {
        items {
          title
          metaTitle
          metaDescription
          blurb
          copyright
          email
          entriesPerPage
          author {
            slug
            name
            profilePicture {
              width
              height
              url
              description
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
          coverImage {
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
      events: eventCollection(skip: $skip, limit: $limit, order: [date_ASC], where: { canceled: false }) {
        items {
          title
          description
          location
          url
          trackingUrl
          date
          sys {
            id
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
end
