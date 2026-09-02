# The shared Contentful GraphQL client: the endpoint, the check on the env vars, the common POST and
# parse code, and the skip and limit pages. It reports an upstream failure with the label of the
# service that called it, thus Bugsnag makes one group for each caller.
class ContentfulClient < ApplicationService
  CONTENTFUL_API_URL = "https://graphql.contentful.com/content/v1/spaces"
  PAGE_SIZE = 100

  # @param service_label [String] The name of the service that calls this class, for the error
  #   report.
  def initialize(service_label = self.class.name)
    @service_label = service_label
  end

  # Does a GraphQL query.
  # @param gql [String] The query.
  # @param variables [Hash, nil] The variables of the query.
  # @return [Hash, nil] The `data` of the response, with symbol keys, or nil if there is no
  #   configuration or the request fails.
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

  # Does a query and gets the items of one collection.
  # @param collection [Symbol] The key of the collection in `data`.
  # @return [Array<Hash>, nil] The items, or nil if it fails.
  def items(gql, variables = nil, collection:)
    query(gql, variables)&.dig(collection, :items)
  end

  # Reads a collection query with skip and limit, one page at a time.
  # @param collection [Symbol] The key of the collection in `data`.
  # @param strict [Boolean] True if a page that fails must stop the full fetch. Use it for a caller
  #   that must not act on an incomplete set. With false, a page that fails ends the loop.
  # @return [Array<Hash>, nil] All the items, or nil when a page fails and `strict` is true.
  def paginate(gql, collection:, page_size: PAGE_SIZE, strict: false)
    all = []
    skip = 0
    MAX_PAGES.times do
      page = items(gql, { skip: skip, limit: page_size }, collection: collection)
      if page.nil?
        return nil if strict
        return all
      end
      all.concat(page)
      return all if page.size < page_size

      skip += page_size
    end

    # ⚠️ A query that omits `skip` from its arguments gives a full page for all time. The loop
    # ends here, with a report, and does not grow the list until the worker runs out of memory.
    report_upstream_error("pagination did not end after #{MAX_PAGES} pages", context: "ContentfulClient #{collection}")
    strict ? nil : all
  end

  # The most pages of one collection. The largest collection is the assets, at some hundreds.
  MAX_PAGES = 100

  private

  # This reports with the label of the caller, and not with "ContentfulClient". Thus the first line
  # in Bugsnag names the caller that failed.
  def report_upstream_error(error, context: @service_label, status: nil, url: nil)
    ErrorReporter.report_upstream(error, service: @service_label, context: context, status: status, url: url)
  end
end
