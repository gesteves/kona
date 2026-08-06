# Shared Contentful GraphQL client: the endpoint, env guard, POST and parse boilerplate, and
# skip/limit pagination. Upstream failures are reported under the consumer's service label, so
# Bugsnag grouping stays per-consumer.
class ContentfulClient < ApplicationService
  CONTENTFUL_API_URL = "https://graphql.contentful.com/content/v1/spaces"
  PAGE_SIZE = 100

  # @param service_label [String] The consuming service's name, used for error reporting.
  def initialize(service_label = self.class.name)
    @service_label = service_label
  end

  # Runs a GraphQL query.
  # @param gql [String] The query.
  # @param variables [Hash, nil] Its variables.
  # @return [Hash, nil] The response's symbolized `data`, or nil when unconfigured or failed.
  def query(gql, variables = nil)
    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    return if space.blank? || token.blank?

    body = { query: gql }
    body[:variables] = variables if variables.present?

    post_json(
      "#{CONTENTFUL_API_URL}/#{space}",
      body: body.to_json,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    )&.dig(:data)
  end

  # Runs a query and pulls out one collection's items.
  # @param collection [Symbol] The collection key under `data`.
  # @return [Array<Hash>, nil] The items, or nil on failure.
  def items(gql, variables = nil, collection:)
    query(gql, variables)&.dig(collection, :items)
  end

  # Pages through a skip/limit collection query.
  # @param collection [Symbol] The collection key under `data`.
  # @param strict [Boolean] Whether a failed page aborts the whole fetch, for callers that must
  #   not act on a partial corpus. Otherwise a failed page just ends the loop.
  # @return [Array<Hash>, nil] Every item, or nil when a page failed under `strict`.
  def paginate(gql, collection:, page_size: PAGE_SIZE, strict: false)
    all = []
    skip = 0
    loop do
      page = items(gql, { skip: skip, limit: page_size }, collection: collection)
      if page.nil?
        return nil if strict
        break
      end
      all.concat(page)
      break if page.size < page_size
      skip += page_size
    end
    all
  end

  private

  # Reports under the consumer's label rather than "ContentfulClient", so the failing consumer
  # stays visible in the Bugsnag headline.
  def report_upstream_error(error, context: @service_label, status: nil, url: nil)
    ErrorReporter.report_upstream(error, service: @service_label, context: context, status: status, url: url)
  end
end
