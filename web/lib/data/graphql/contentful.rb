require "graphql/client"
require "graphql/client/http"
require "dotenv"

module ContentfulClient
  Dotenv.load

  HTTP = GraphQL::Client::HTTP.new("https://graphql.contentful.com/content/v1/spaces/#{ENV['CONTENTFUL_SPACE']}") do
    def headers(context)
      { "Authorization": "Bearer #{ENV['CONTENTFUL_TOKEN']}" }
    end
  end

  # `rake import:schema` writes the schema to this file, and `rake import` includes that. With the
  # file, `rake test` needs no request to Contentful. With no file, the code reads the live schema.
  SCHEMA_PATH = File.expand_path("contentful_schema.json", __dir__)
  Schema = GraphQL::Client.load_schema(File.exist?(SCHEMA_PATH) ? SCHEMA_PATH : HTTP)
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
      mastodon
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
          showAffiliateLinksDisclosure
          canonicalUrl
          coverImage {
            ...ImageFields
          }
          sys {
            ...SysFields
          }
          contentfulMetadata {
            concepts {
              id
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
          showRecommendations
          coverImage {
            ...ImageFields
          }
          sys {
            ...SysFields
          }
        }
      }
    }

    # No `preview: true`, on purpose: a draft of the Site entry must not ship, and the newest
    # published one is the site.
    query Sites {
      sites: siteCollection(limit: 1, order: [sys_publishedAt_DESC]) {
        items {
          title
          metaTitle
          metaDescription
          blurb
          copyright
          email
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
          coverImage {
            ...ImageFields
          }
          smallLogo {
            ...ImageFields
          }
          sys {
            ...SysFields
          }
        }
      }
    }

    # No `preview: true`, on purpose: a draft redirect must not go into _redirects.
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

    # No `preview: true`, on purpose: a draft race must not show on the home page. ⚠️ Articles,
    # Pages, and Assets DO use it, thus a draft entry renders at /id/<id>/. A draft asset points at
    # the mirror, which holds published assets only, thus its image on that preview gives a 404.
    query Events($skip: Int, $limit: Int) {
      events: eventCollection(skip: $skip, limit: $limit) {
        items {
          title
          summary
          description
          location
          url
          date
          going
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
