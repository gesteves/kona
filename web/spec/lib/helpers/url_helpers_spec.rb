require 'spec_helper'

RSpec.describe UrlHelpers do
  # Middleman's url_for resolves a resource to its path; identity is enough here.
  def url_for(resource) = resource

  def stub_env(context: nil, url: nil, deploy_url: nil, deploy_context: nil)
    allow(ENV).to receive(:[]).and_call_original
    # DEPLOY_CONTEXT must be stubbed too, not just CONTEXT: production? reads it first
    # (context_helpers.rb), and a real build env sets it — e.g. DEPLOY_CONTEXT=production
    # for the Cloudflare build, which rake loads from .env before the suite runs. Left
    # unstubbed it leaks through and_call_original and forces production? true here.
    allow(ENV).to receive(:[]).with('DEPLOY_CONTEXT').and_return(deploy_context)
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
      expect(full_url('/about/', foo: 'bar')).to eq('https://example.com/about/?foo=bar')
    end
  end
end
