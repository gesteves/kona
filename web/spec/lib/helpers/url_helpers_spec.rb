require 'spec_helper'

RSpec.describe UrlHelpers do
  # The url_for of Middleman changes a resource into its path. A method that returns its argument
  # is sufficient here.
  def url_for(resource) = resource

  # Each test must stub DEPLOY_CONTEXT, and this includes a test that does not use it. A true
  # build environment sets it, for example DEPLOY_CONTEXT=production, which rake loads from .env
  # before the suite runs. Without a stub, that value makes production? true here.
  def stub_site_env(deploy_context: nil, url: nil)
    stub_env('DEPLOY_CONTEXT' => deploy_context, 'URL' => url)
  end

  describe '#root_url' do
    it 'uses the site URL on a production build' do
      stub_site_env(deploy_context: 'production', url: 'https://example.com')
      expect(root_url).to eq('https://example.com')
    end

    it 'defaults to localhost outside a production build' do
      stub_site_env
      expect(root_url).to eq('http://localhost:4567')
    end
  end

  describe '#full_url' do
    before { stub_site_env(deploy_context: 'production', url: 'https://example.com') }

    it 'joins the root URL and the resource path' do
      expect(full_url('/about/')).to eq('https://example.com/about/')
    end

    it 'appends query params when given' do
      expect(full_url('/about/', foo: 'bar')).to eq('https://example.com/about/?foo=bar')
    end
  end
end
