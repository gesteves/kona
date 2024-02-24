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
  # In production, it uses the site URL set by Netlify.
  # On other Netlify environments (like dev and branch previews), it uses the 'DEPLOY_URL' environment variable.
  # Outside of Netlify, like running `middleman server`, defaults to 'http://localhost:4567'.
  # @see https://docs.netlify.com/configure-builds/environment-variables/#deploy-urls-and-metadata
  # @return [String] The root URL of the application.
  def root_url
    if is_production?
      ENV['URL']
    elsif is_netlify?
      ENV['DEPLOY_URL']
    else
      'http://localhost:4567'
    end
  end

  # Extracts and returns the domain from the application's root URL.
  # @return [String] The domain of the application's root URL.
  def site_domain
    uri = URI.parse(root_url)
    domain = PublicSuffix.domain(uri.host)
  end
end
