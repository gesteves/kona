module UrlHelpers
  # Makes the absolute URL of a Middleman resource.
  # @param resource [Object] The resource, the path, or the URL.
  # @param params [Hash] The query parameters to add at the end.
  # @return [String] The absolute URL.
  def full_url(resource, params = {})
    url = URI.parse(root_url)
    url.path = url_for(resource)
    url.query = URI.encode_www_form(params) if params.present?
    url.to_s
  end

  # @return [String] The origin of the site: `URL` in a production build, and localhost in each
  #   other condition. There is no remote build that is not production: the deploy workflow sends
  #   only main, and the Worker has no preview URL.
  def root_url
    production? ? ENV["URL"] : "http://localhost:4567"
  end
end
