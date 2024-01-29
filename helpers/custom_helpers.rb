require 'active_support/all'

module CustomHelpers
  include ActiveSupport::NumberHelper

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

  def root_url
    if is_production?
      ENV['URL']
    elsif is_netlify?
      ENV['DEPLOY_URL']
    else
      'http://localhost:4567'
    end
  end

  def site_domain
    PublicSuffix.domain(root_url)
  end

  # Determines if the site is currently running on Netlify, based on the presence of a CONTEXT env var.
  # @see https://docs.netlify.com/configure-builds/environment-variables/#build-metadata
  # @return [Boolean] True if the site is on Netlify.
  def is_netlify?
    ENV['CONTEXT'].present?
  end

  # Determines if the site is currently running on Netlify in production.
  # @return [Boolean] True if the site is on prod.
  def is_production?
    ENV['CONTEXT'] == 'production'
  end

  # Determines if the site is currently running on dev using `netlify dev`.
  # @return [Boolean] True if the site is on Netlify's dev environment.
  def is_dev?
    ENV['CONTEXT'] == 'dev'
  end
end
