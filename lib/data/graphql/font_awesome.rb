require 'graphql/client'
require 'graphql/client/http'
require 'dotenv'
require 'httparty'
require 'redis'

module FontAwesomeClient
  Dotenv.load

  FONT_AWESOME_API_URL = "https://api.fontawesome.com"

  $redis ||= Redis.new(
    host: ENV['REDIS_HOST'] || 'localhost',
    port: ENV['REDIS_PORT'] || 6379,
    username: ENV['REDIS_USERNAME'],
    password: ENV['REDIS_PASSWORD']
  )

  def self.get_access_token(api_token)
    access_token = $redis.get("font_awesome:access_token")
    return access_token if access_token.present?

    headers = {
      "Authorization" => "Bearer #{api_token}",
      "Content-Type" => "application/json"
    }

    response = HTTParty.post("#{FONT_AWESOME_API_URL}/token", headers: headers)
    return unless response.success?

    data = JSON.parse(response.body, symbolize_names: true)
    access_token = data[:access_token]
    expires_in = data[:expires_in]
    $redis.setex("font_awesome:access_token", expires_in, access_token)
    access_token
  rescue StandardError => e
    puts "Error fetching the access token: #{e}"
    nil
  end

  # Creates the HTTP client for GraphQL
  HTTP = GraphQL::Client::HTTP.new(FONT_AWESOME_API_URL) do
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
