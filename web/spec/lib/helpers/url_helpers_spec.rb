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

  describe '#feed_url' do
    before { stub_env(context: 'production', url: 'https://example.com') }

    # Asserted as a literal string, not a parsed hash: the feed-source edge function
    # substitutes the literal `utm_source=Feed&`, so the key order is part of the contract.
    it 'emits utm_source first, so the edge function can anchor on it' do
      expect(feed_url('/about/')).to eq('https://example.com/about/?utm_source=Feed&utm_medium=feed')
    end

    it 'appends utm_campaign when a campaign is given' do
      expect(feed_url('/about/', campaign: 'triathlon'))
        .to eq('https://example.com/about/?utm_source=Feed&utm_medium=feed&utm_campaign=triathlon')
    end

    it 'omits utm_campaign when the campaign is nil or blank' do
      expect(feed_url('/about/', campaign: nil)).not_to include('utm_campaign')
      expect(feed_url('/about/', campaign: '')).not_to include('utm_campaign')
    end
  end
end
