require 'spec_helper'
require 'ostruct'

RSpec.describe ImageHelpers do
  # Shaped like data.assets; @assets is set per example before the index is built.
  def data = OpenStruct.new(assets: @assets || [])

  def stub_env(context: nil, url: nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('CONTEXT').and_return(context)
    allow(ENV).to receive(:[]).with('URL').and_return(url)
  end

  before { stub_env }

  describe '#get_asset_id' do
    it 'extracts the asset id segment from a Contentful URL' do
      expect(get_asset_id('https://images.ctfassets.net/space/asset-1/token/photo.jpg')).to eq('asset-1')
    end

    it 'is nil for a blank URL' do
      expect(get_asset_id(nil)).to be_nil
      expect(get_asset_id('')).to be_nil
    end
  end

  describe 'asset lookups' do
    before do
      @assets = [
        OpenStruct.new(
          sys: OpenStruct.new(id: 'asset-1', published_version: 7),
          url: 'https://images.ctfassets.net/space/asset-1/token/photo.jpg',
          width: 1600, height: 900, description: ' A finish line ', content_type: 'image/jpeg'
        )
      ]
    end

    it 'looks up dimensions, description, content type, URL, and version by id' do
      expect(get_asset_dimensions('asset-1')).to eq([1600, 900])
      expect(get_asset_description('asset-1')).to eq('A finish line')
      expect(get_asset_content_type('asset-1')).to eq('image/jpeg')
      expect(get_asset_url('asset-1')).to eq('https://images.ctfassets.net/space/asset-1/token/photo.jpg')
      expect(get_asset_published_version('asset-1')).to eq(7)
    end

    it 'returns nils for an unknown asset' do
      expect(get_asset_dimensions('nope')).to eq([nil, nil])
      expect(get_asset_description('nope')).to be_nil
    end
  end

  describe '#merge_query' do
    it 'appends params to a bare URL' do
      expect(merge_query('https://example.com/a.jpg', w: 100)).to eq('https://example.com/a.jpg?w=100')
    end

    it 'preserves existing params and overrides duplicates' do
      merged = merge_query('https://example.com/a.jpg?fm=jpg&w=50', 'w' => 100)
      expect(merged).to eq('https://example.com/a.jpg?fm=jpg&w=100')
    end
  end

  describe '#cdn_image_url' do
    let(:original) { 'https://images.ctfassets.net/space/asset-1/token/photo.jpg' }

    it 'is nil for a blank URL' do
      expect(cdn_image_url(nil)).to be_nil
    end

    context 'outside Netlify (Contentful Images API)' do
      it 'merges the params into the URL' do
        expect(cdn_image_url(original, w: 100)).to eq("#{original}?w=100")
      end

      it "translates Netlify's fit=cover to Contentful's fit=fill" do
        expect(cdn_image_url(original, fit: 'cover')).to eq("#{original}?fit=fill")
      end
    end

    context 'on Netlify' do
      before { stub_env(context: 'production', url: 'https://example.com') }

      it 'routes through the Netlify Image CDN with the source URL encoded' do
        url = cdn_image_url(original, w: 100)
        expect(url).to start_with('https://example.com/.netlify/images?url=')
        expect(url).to include(URI.encode_www_form_component(original))
        expect(url).to end_with('&w=100')
      end

      it 'upgrades protocol-relative URLs to https' do
        url = cdn_image_url('//images.ctfassets.net/space/a/t/p.jpg')
        expect(url).to include(URI.encode_www_form_component('https://images.ctfassets.net/space/a/t/p.jpg'))
      end

      it 'merges params into a URL already on the image CDN' do
        url = cdn_image_url('https://example.com/.netlify/images?url=x&w=50', 'w' => 100)
        expect(url).to eq('https://example.com/.netlify/images?url=x&w=100')
      end
    end

    it "swaps in the asset's canonical URL when the id is known" do
      @assets = [OpenStruct.new(sys: OpenStruct.new(id: 'asset-1'), url: 'https://cdn.example.com/canonical.jpg')]
      expect(cdn_image_url(original, w: 10)).to eq('https://cdn.example.com/canonical.jpg?w=10')
    end
  end

  describe '#srcset' do
    it 'renders a width-described candidate per size' do
      set = srcset(url: 'https://images.ctfassets.net/s/a/t/p.jpg', widths: [100, 200])
      expect(set).to eq('https://images.ctfassets.net/s/a/t/p.jpg?w=100 100w, https://images.ctfassets.net/s/a/t/p.jpg?w=200 200w')
    end

    it 'crops square when asked' do
      set = srcset(url: 'https://images.ctfassets.net/s/a/t/p.jpg', widths: [100], square: true)
      expect(set).to include('w=100')
      expect(set).to include('h=100')
      expect(set).to include('fit=fill') # cover → fill outside Netlify
    end
  end

  describe '#open_graph_image_url' do
    it "uses Facebook's card dimensions" do
      url = open_graph_image_url('https://images.ctfassets.net/s/a/t/p.jpg')
      expect(url).to include('w=1200')
      expect(url).to include('h=630')
    end
  end
end
