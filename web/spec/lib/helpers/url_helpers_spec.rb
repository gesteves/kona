require 'spec_helper'

RSpec.describe UrlHelpers do
  # Middleman's url_for resolves a resource to its path; identity is enough here.
  def url_for(resource) = resource

  def stub_env(context: nil, url: nil, deploy_url: nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('CONTEXT').and_return(context)
    allow(ENV).to receive(:[]).with('URL').and_return(url)
    allow(ENV).to receive(:[]).with('DEPLOY_URL').and_return(deploy_url)
  end

  describe '#root_url' do
    it 'uses the Netlify site URL in production' do
      stub_env(context: 'production', url: 'https://example.com')
      expect(root_url).to eq('https://example.com')
    end

    it 'uses the deploy URL on non-production Netlify environments' do
      stub_env(context: 'deploy-preview', deploy_url: 'https://deploy-preview-5--example.netlify.app')
      expect(root_url).to eq('https://deploy-preview-5--example.netlify.app')
    end

    it 'defaults to localhost outside Netlify' do
      stub_env
      expect(root_url).to eq('http://localhost:4567')
    end
  end

  describe '#full_url' do
    before { stub_env(context: 'production', url: 'https://example.com') }

    it 'joins the root URL and the resource path' do
      expect(full_url('/about/')).to eq('https://example.com/about/')
    end

    it 'appends query params when given' do
      expect(full_url('/about/', ref: 'Feed')).to eq('https://example.com/about/?ref=Feed')
    end
  end

  describe '#site_domain' do
    it 'extracts the registrable domain from the root URL' do
      stub_env(context: 'production', url: 'https://www.example.com')
      expect(site_domain).to eq('example.com')
    end
  end
end
