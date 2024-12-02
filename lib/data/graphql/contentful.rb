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

    query Articles($skip: Int, $limit: Int) {
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
          blueskyCommentsUrl
          commentsPrompt
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
    }

    query Pages($skip: Int, $limit: Int) {
      pages: pageCollection(skip: $skip, limit: $limit, preview: true) {
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
    }

    query Sites {
      sites: siteCollection(limit: 1, order: [sys_publishedAt_DESC]) {
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
          openGraphImageLogo {
            ...ImageFields
          }
          sys {
            ...SysFields
          }
        }
      }
    }

    query Redirects($skip: Int, $limit: Int) {
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
    }

    query Events($skip: Int, $limit: Int) {
      events: eventCollection(skip: $skip, limit: $limit, where: { canceled: false }) {
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
    }

    query Assets($skip: Int, $limit: Int) {
      assets: assetCollection(skip: $skip, limit: $limit, preview: true) {
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
