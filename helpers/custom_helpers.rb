require 'active_support/all'

module CustomHelpers
  include ActiveSupport::NumberHelper

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
