require 'graphql/client'
require 'graphql/client/http'
require 'dotenv'
require 'httparty'
require 'redis'

module FontAwesomeClient
  Dotenv.load

  REDIS = Redis.new(
    host: ENV['REDIS_HOST'] || 'localhost',
    port: ENV['REDIS_PORT'] || 6379,
    username: ENV['REDIS_USERNAME'],
    password: ENV['REDIS_PASSWORD']
  )

  def self.get_access_token(api_token)
    access_token = REDIS.get("font_awesome:access_token")
    return access_token if access_token.present?

    response = HTTParty.post(
      "https://api.fontawesome.com/token",
      headers: { "Authorization" => "Bearer #{api_token}", "Content-Type" => "application/json" }
    )
    if response.code == 200
      access_token = response.parsed_response["access_token"]
      expires_in = response.parsed_response["expires_in"]

      REDIS.setex("font_awesome:access_token", expires_in, access_token)

      access_token
    else
      puts "Error fetching the access token: #{response.body}"
      nil
    end
  rescue StandardError => e
    puts "Error fetching the access token: #{e}"
    nil
  end

  # Creates the HTTP client for GraphQL
  HTTP = GraphQL::Client::HTTP.new("https://api.fontawesome.com") do
    def headers(context)
      { "Authorization": "Bearer #{FontAwesomeClient.get_access_token(ENV['FONT_AWESOME_API_TOKEN'])}" }
    end
  end

  # Load the GraphQL schema
  Schema = GraphQL::Client.load_schema(HTTP)

  # Create the GraphQL client
  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

  QUERIES = Client.parse <<-'GRAPHQL'
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
end
