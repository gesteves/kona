module UrlHelpers
  # Constructs the full URL for a given Middleman resource, depending on the environment.
  # @param resource [Object] The resource for which the URL is being generated.
  # @param params [Hash] (Optional) Additional query parameters to be included in the URL.
  # @return [String] The fully constructed URL as a string.
  def full_url(resource, params = {})
    url = URI.parse(root_url)
    url.path = url_for(resource)
    url.query = URI.encode_www_form(params) if params.present?
    url.to_s
  end

  # Returns the root URL of the application based on the environment.
  # On a production build it uses the site's public origin, `URL` (set in the build env).
  # Anywhere else — `middleman server`, a local build — it defaults to
  # 'http://localhost:4567'. There is no remote non-production build: the deploy workflow
  # only ships from main, and the Worker has no preview URLs (`workers_dev: false`).
  # @return [String] The root URL of the application.
  def root_url
    production? ? ENV['URL'] : 'http://localhost:4567'
  end
end
