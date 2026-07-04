require 'spec_helper'
require 'ostruct'

RSpec.describe ShareHelpers do
  # Collaborators normally mixed in from other helper modules, pinned here for determinism.
  def sanitize(text, **) = text

  def full_url(path, params = {})
    query = params.present? ? "?#{URI.encode_www_form(params)}" : ''
    "https://example.com#{path}#{query}"
  end

  let(:article) { OpenStruct.new(title: 'My Race Report', path: '/2026/06/15/my-race-report/') }

  describe '#share_url' do
    it 'builds a mailto URL with the title as subject and the URL as body' do
      url = share_url('Email', article)
      expect(url).to eq('mailto:?subject=My%20Race%20Report&body=https%3A%2F%2Fexample.com%2F2026%2F06%2F15%2Fmy-race-report%2F%3Fref%3DEmail')
    end

    it 'builds an SMS URL with title and URL in one body' do
      url = share_url('SMS', article)
      expect(url).to start_with('sms:?&body=')
      expect(url).to include('My%20Race%20Report%20https%3A%2F%2F')
    end

    it 'builds a Facebook sharer URL carrying only the article URL' do
      url = share_url('Facebook', article)
      expect(url).to start_with('https://www.facebook.com/sharer/sharer.php?u=')
      expect(url).not_to include('My%20Race%20Report')
    end

    it 'builds a Reddit URL with separate title and url params' do
      url = share_url('Reddit', article)
      expect(url).to start_with('https://reddit.com/submit?title=My%20Race%20Report&url=')
    end

    it 'composes title and URL on separate lines for Bluesky and Mastodon' do
      %w[Bluesky Mastodon].each do |network|
        url = share_url(network, article)
        expect(url).to include('My%20Race%20Report%0A%0Ahttps%3A%2F%2F')
      end
    end

    it 'builds a Threads intent URL with separate text and url params' do
      url = share_url('Threads', article)
      expect(url).to start_with('https://www.threads.com/intent/post?text=My%20Race%20Report&url=')
    end

    it 'tags each network share URL with its own ?ref= attribution' do
      described_class::SHARE_NETWORKS.each_key do |network|
        expect(share_url(network, article)).to include(ERB::Util.url_encode("ref=#{network}"))
      end
    end

    it 'raises for an unknown network' do
      expect { share_url('Myspace', article) }.to raise_error(KeyError)
    end
  end

  describe '#share_buttons' do
    it 'lists a button for every share network' do
      expect(share_buttons.map { |b| b[:network] }).to match_array(described_class::SHARE_NETWORKS.keys)
    end

    it "tracks SMS shares as 'Text'" do
      sms = share_buttons.find { |b| b[:network] == 'SMS' }
      expect(sms[:via]).to eq('Text')
    end

    it 'opens Facebook through the popup action' do
      facebook = share_buttons.find { |b| b[:network] == 'Facebook' }
      expect(facebook[:action]).to eq('openPopup')
    end

    it 'keeps mail and SMS in the same tab' do
      share_buttons.each do |button|
        expected = !%w[Email SMS].include?(button[:network])
        expect(button.fetch(:new_tab, true)).to be(expected)
      end
    end
  end

  describe '#share_heading' do
    def article_with(tags: [], entry_type: 'Article')
      OpenStruct.new(
        entry_type: entry_type,
        contentful_metadata: OpenStruct.new(tags: tags.map { |t| OpenStruct.new(name: t) })
      )
    end

    it 'calls out race reports and reviews by their tag' do
      expect(share_heading(article_with(tags: ['Race Reports']))).to eq('Share this race report')
      expect(share_heading(article_with(tags: ['Reviews']))).to eq('Share this review')
    end

    it 'falls back to the entry type' do
      expect(share_heading(article_with(entry_type: 'Article'))).to eq('Share this article')
      expect(share_heading(article_with(entry_type: 'Short'))).to eq('Share this post')
    end
  end
end
