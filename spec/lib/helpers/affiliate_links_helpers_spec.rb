require 'spec_helper'

RSpec.describe AffiliateLinksHelpers do
  describe '#has_amazon_associates_links?' do
    let(:content_with_affiliate) { double('Content', intro: 'Check out this product', body: '<a href="https://www.amazon.com/example?tag=affiliate-20">Product Link</a>') }
    let(:content_without_affiliate) { double('Content', intro: 'Just some intro', body: '<a href="https://example.com">Normal Link</a>') }

    it 'returns true for content with affiliate links' do
      expect(has_amazon_associates_links?(content_with_affiliate)).to be true
    end

    it 'returns false for content without affiliate links' do
      expect(has_amazon_associates_links?(content_without_affiliate)).to be false
    end
  end

  describe '#is_amazon_associates_link?' do
    it 'returns true for an Amazon affiliate link' do
      expect(is_amazon_associates_link?('https://www.amazon.com/example?tag=affiliate-20')).to be true
    end

    it 'returns true for an Amazon short link' do
      expect(is_amazon_associates_link?('https://amzn.to/abc123')).to be true
    end

    it 'returns false for a non-affiliate Amazon link' do
      expect(is_amazon_associates_link?('https://amazon.com/product')).to be false
    end

    it 'returns false for non-Amazon links' do
      expect(is_amazon_associates_link?('https://example.com')).to be false
    end
  end
end
