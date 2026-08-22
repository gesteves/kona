require "graphql/client"
require "graphql/client/http"
require "httparty"

# The GraphQL client of the Font Awesome API. It is the same as
# lib/data/graphql/font_awesome.rb of the web app. The code makes the HTTP client and the schema at
# the first use. Thus the start of the app, and a test run with a stub for FontAwesome, never use
# the network.
module FontAwesomeClient
  FONT_AWESOME_API_URL = "https://api.fontawesome.com"

  # The seconds that the code subtracts from the life of the token before it puts it in the
  # cache.
  TOKEN_EXPIRY_MARGIN = 60

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
    # Gets an API access token with a short life, and puts it in Redis.
    def get_access_token(api_token)
      access_token = $redis.get("font_awesome:access_token")
      return access_token if access_token.present?

      headers = {
        "Authorization" => "Bearer #{api_token}",
        "Content-Type" => "application/json"
      }

      response = HTTParty.post("#{FONT_AWESOME_API_URL}/token", headers: headers)
      unless response.success?
        ErrorReporter.report_upstream("HTTP #{response.code}", service: "FontAwesomeClient", context: "Font Awesome token", status: response.code, url: "#{FONT_AWESOME_API_URL}/token")
        return
      end

      data = JSON.parse(response.body, symbolize_names: true)
      # ⚠️ The cache holds the token for less than its true life, as it does for the JWT of
      # WeatherKit. The extra time is for a clock difference and for a request in progress. With
      # the exact time, a request at the end of the window would get a token that expired. That
      # failure has no message: the GraphQL call gives nil and the view renders a widget with one
      # icon absent. An expires_in that is absent or zero would make setex raise into that same
      # rescue, and the token would then stay out of the cache.
      ttl = data[:expires_in].to_i - TOKEN_EXPIRY_MARGIN
      $redis.setex("font_awesome:access_token", ttl, data[:access_token]) if ttl.positive?
      data[:access_token]
    rescue StandardError => e
      Rails.logger.error("Error fetching the Font Awesome access token: #{e}")
      ErrorReporter.report_upstream(e, service: "FontAwesomeClient", context: "Font Awesome token")
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
      # client.parse returns a Module, and each named operation in it is a constant. This query is
      # `query Icons`. The code must give that module a *name*: graphql-client makes the operation
      # name that it sends from the name of the module, thus a module with no name gives incorrect
      # GraphQL ("query #<Module:0x..>__Icons").
      const_set(:Queries, client.parse(ICONS_QUERY)) unless const_defined?(:Queries, false)
      self::Queries::Icons
    end
  end
end
