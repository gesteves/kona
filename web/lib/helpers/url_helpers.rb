module UrlHelpers
  # Builds the absolute URL for a Middleman resource.
  # @param resource [Object] The resource, path, or URL.
  # @param params [Hash] Query parameters to append.
  # @return [String] The absolute URL.
  def full_url(resource, params = {})
    url = URI.parse(root_url)
    url.path = url_for(resource)
    url.query = URI.encode_www_form(params) if params.present?
    url.to_s
  end

  # @return [String] The site's origin: `URL` on a production build, localhost otherwise.
  #   There is no remote non-production build — the deploy workflow only ships from main and
  #   the Worker has no preview URLs.
  def root_url
    production? ? ENV["URL"] : "http://localhost:4567"
  end
end
