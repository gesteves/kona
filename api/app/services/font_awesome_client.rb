require "graphql/client"
require "graphql/client/http"
require "httparty"

# GraphQL client for the Font Awesome API, mirroring the web app's
# lib/data/graphql/font_awesome.rb. The HTTP client and schema are built lazily on
# first use so booting the app (and running tests with FontAwesome stubbed) never
# hits the network.
module FontAwesomeClient
  FONT_AWESOME_API_URL = "https://api.fontawesome.com"

  ICONS_QUERY = <<-'GRAPHQL'
    query Icons ($version: String!, $query: String!) {
      search(version: $version, query: $query) {
        id
        svgs {
          familyStyle {
            family
            style
          }
          html
        }
      }
    }
  GRAPHQL

  class << self
    # Fetches (and caches in Redis) a short-lived API access token.
    def get_access_token(api_token)
      access_token = $redis.get("font_awesome:access_token")
      return access_token if access_token.present?

      headers = {
        "Authorization" => "Bearer #{api_token}",
        "Content-Type" => "application/json"
      }

      response = HTTParty.post("#{FONT_AWESOME_API_URL}/token", headers: headers)
      return unless response.success?

      data = JSON.parse(response.body, symbolize_names: true)
      $redis.setex("font_awesome:access_token", data[:expires_in], data[:access_token])
      data[:access_token]
    rescue StandardError => e
      Rails.logger.error("Error fetching the Font Awesome access token: #{e}")
      nil
    end

    def client
      @client ||= begin
        http = GraphQL::Client::HTTP.new(FONT_AWESOME_API_URL) do
          def headers(_context)
            { "Authorization": "Bearer #{FontAwesomeClient.get_access_token(ENV['FONT_AWESOME_API_TOKEN'])}" }
          end
        end
        schema = GraphQL::Client.load_schema(http)
        graphql_client = GraphQL::Client.new(schema: schema, execute: http)
        graphql_client.allow_dynamic_queries = true
        graphql_client
      end
    end

    def icons_query
      # client.parse returns a Module whose named operations are nested constants
      # (this query is `query Icons`). It must be assigned to a *named* constant:
      # graphql-client derives the wire operation name from the module's name, so an
      # anonymous module produces invalid GraphQL ("query #<Module:0x..>__Icons").
      const_set(:Queries, client.parse(ICONS_QUERY)) unless const_defined?(:Queries, false)
      self::Queries::Icons
    end
  end
end
