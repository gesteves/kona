require 'active_support/all'

module CustomHelpers
  include ActiveSupport::NumberHelper

  # Constructs the full URL for a given resource, considering the environment and additional parameters.
  # @param resource [Object] The resource for which the URL is being generated.
  # @param params [Hash] (Optional) Additional query parameters to be included in the URL.
  # @return [String] The fully constructed URL as a string.
  def full_url(resource, params = {})
    base_url = if is_production?
      ENV['URL']
    elsif is_netlify? && !is_production?
      ENV['DEPLOY_URL']
    else
      'http://localhost:4567'
    end
    url = URI.parse(base_url)
    url.path = url_for(resource)
    url.query = URI.encode_www_form(params) if params.present?
    url.to_s
  end

  # Determines if the site is currently running on Netlify.
  # @return [Boolean] True if the site is on Netlify.
  def is_netlify?
    ENV['NETLIFY'].present?
  end

  # Determines if the site is currently running on Netlify in production.
  # @return [Boolean] True if the site is on prod.
  def is_production?
    ENV['NETLIFY'].present? && ENV['CONTEXT'] == 'production'
  end

  # Determines if the site is currently running on dev using `netlify dev`.
  # @return [Boolean] True if the site is on Netlify's dev environment.
  def is_dev?
    ENV['NETLIFY'].present? && ENV['CONTEXT'] == 'dev'
  end

  # Determines if the site is currently running or being built outside of Netlify.
  # @return [Boolean] True if the site is not on Netlify.
  def is_middleman?
    !is_netlify?
  end
end
