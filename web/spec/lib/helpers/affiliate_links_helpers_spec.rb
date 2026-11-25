require 'spec_helper'

RSpec.describe AffiliateLinksHelpers do
  describe '#has_amazon_associates_links?' do
    let(:content_with_affiliate) { double('Content', sys: double('Sys', id: 'with-affiliate'), intro: 'Check out this product', body: '<a href="https://www.amazon.com/example?tag=affiliate-20">Product Link</a>') }
    let(:content_without_affiliate) { double('Content', sys: double('Sys', id: 'without-affiliate'), intro: 'Just some intro', body: '<a href="https://example.com">Normal Link</a>') }

    it 'returns true for content with affiliate links' do
      expect(has_amazon_associates_links?(content_with_affiliate)).to be true
    end

    it 'returns false for content without affiliate links' do
      expect(has_amazon_associates_links?(content_without_affiliate)).to be false
    end
  end

  describe '#amazon_associates_link?' do
    it 'returns true for an Amazon affiliate link' do
      expect(amazon_associates_link?('https://www.amazon.com/example?tag=affiliate-20')).to be true
    end

    it 'returns true for an Amazon short link' do
      expect(amazon_associates_link?('https://amzn.to/abc123')).to be true
    end

    it 'returns false for a non-affiliate Amazon link' do
      expect(amazon_associates_link?('https://amazon.com/product')).to be false
    end

    it 'returns false for non-Amazon links' do
      expect(amazon_associates_link?('https://example.com')).to be false
    end
  end

  describe '#affiliate_links_disclosure' do
    def entry(entry_type:, body: 'No links here.')
      double('Entry', sys: double('Sys', id: 'entry-1'), entry_type: entry_type,
                      show_affiliate_links_disclosure: true, intro: nil, body: body)
    end

    it "names the entry's type in the disclosure" do
      expect(affiliate_links_disclosure(entry(entry_type: 'Article'))).to include('This article contains affiliate links')
    end

    it "falls back to 'post' when the entry has no type" do
      expect(affiliate_links_disclosure(entry(entry_type: nil))).to include('This post contains affiliate links')
    end
  end
end
