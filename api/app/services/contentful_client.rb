# Shared Contentful GraphQL client: the endpoint, env guard, POST + parse boilerplate, and
# skip/limit pagination that were duplicated across Articles, Events, and StandardSite.
# Upstream failures are reported under the consumer's service label (passed to the
# constructor) so Bugsnag grouping stays per-consumer.
class ContentfulClient < ApplicationService
  CONTENTFUL_API_URL = "https://graphql.contentful.com/content/v1/spaces"
  PAGE_SIZE = 100

  # @param service_label [String] The consuming service's name, used for error reporting.
  def initialize(service_label = self.class.name)
    @service_label = service_label
  end

  # Runs a GraphQL query and returns its `data` hash (symbolized keys), or nil when the API
  # isn't configured or the request failed.
  # @param gql [String] The GraphQL query.
  # @param variables [Hash, nil]
  # @return [Hash, nil]
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

  # Runs a query and returns one collection's `items`, or nil on failure.
  # @param collection [Symbol] The collection key under `data` (e.g. :articles, :events).
  # @return [Array<Hash>, nil]
  def items(gql, variables = nil, collection:)
    query(gql, variables)&.dig(collection, :items)
  end

  # Pages through a skip/limit collection query (the delivery API returns published entries
  # only).
  # @param collection [Symbol] The collection key under `data`.
  # @param strict [Boolean] When true, a failed page aborts the whole fetch (returns nil) —
  #   for callers that must not act on a partial corpus (the standard.site sync). When false,
  #   a failed page just ends the loop, keeping the best-effort pages fetched so far.
  # @return [Array<Hash>, nil]
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

  # Reports under the consumer's label (e.g. "Articles") rather than "ContentfulClient", so
  # the failing consumer stays visible in the Bugsnag headline.
  def report_upstream_error(error, context: @service_label, status: nil, url: nil)
    ErrorReporter.report_upstream(error, service: @service_label, context: context, status: status, url: url)
  end
end
