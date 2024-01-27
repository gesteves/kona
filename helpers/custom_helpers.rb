require 'active_support/all'

module CustomHelpers
  include ActiveSupport::NumberHelper

  # Constructs the full URL for a given resource, considering the environment and additional parameters.
  # @param resource [Object] The resource for which the URL is being generated.
  # @param params [Hash] (Optional) Additional query parameters to be included in the URL.
  # @return [String] The fully constructed URL as a string.
  def full_url(resource, params = {})
    base_url = if ENV['NETLIFY'] && ENV['CONTEXT'] == 'production'
      ENV['URL']
    elsif ENV['NETLIFY'] && ENV['CONTEXT'] != 'production'
      ENV['DEPLOY_URL']
    else
      'http://localhost:4567'
    end
    url = URI.parse(base_url)
    url.path = url_for(resource)
    url.query = URI.encode_www_form(params) if params.present?
    url.to_s
  end
end
