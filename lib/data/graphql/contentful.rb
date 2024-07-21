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
    fragment SysFields on Sys {
      id
      firstPublishedAt
      publishedAt
      publishedVersion
    }

    fragment ImageFields on Asset {
      width
      height
      url
      description
      title
      contentType
    }

    fragment AuthorFields on Author {
      slug
      name
    }

    fragment ShortcutFields on Shortcut {
      title
      destination
      openInNewTab
    }

    query Content ($skip: Int, $limit: Int) {
      articles: articleCollection(skip: $skip, limit: $limit, preview: true) {
        items {
          title
          slug
          intro
          body
          author {
            ...AuthorFields
          }
          summary
          published
          indexInSearchEngines
          canonicalUrl
          coverImage {
            ...ImageFields
          }
          sys {
            ...SysFields
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
            ...ImageFields
          }
          sys {
            ...SysFields
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
            ...AuthorFields
            profilePicture {
              ...ImageFields
            }
          }
          navLinksCollection {
            items {
              ...ShortcutFields
            }
          }
          footerLinksCollection {
            items {
              ...ShortcutFields
            }
          }
          socialsCollection {
            items {
              ...ShortcutFields
            }
          }
          logo {
            ...ImageFields
          }
          sys {
            ...SysFields
          }
        }
      }
      redirects: redirectCollection(skip: $skip, limit: $limit, order: [sys_publishedAt_DESC]) {
        items {
          from
          to
          status
          sys {
            ...SysFields
          }
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
            ...SysFields
          }
        }
      }
      assets: assetCollection(skip: $skip, limit: $limit, preview: true, order: [sys_firstPublishedAt_DESC]) {
        items {
          ...ImageFields
          sys {
            ...SysFields
          }
        }
      }
    }
  GRAPHQL
end
