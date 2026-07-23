require 'spec_helper'
require 'ostruct'

RSpec.describe ImageHelpers do
  # Shaped like data.assets; @assets is set per example before the index is built.
  def data = OpenStruct.new(assets: @assets || [])

  # IMAGES_URL is the host Cloudflare serves transformations from, and is required everywhere —
  # there's no Contentful-resizing fallback, so unset means raise. Nothing here reads CONTEXT or
  # URL. Defaults to set, since that's every environment the code supports.
  def stub_env(images_url: 'https://example.com')
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('IMAGES_URL').and_return(images_url)
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

    it 'routes through Cloudflare, with the options in the path and the source URL after them' do
      url = cdn_image_url(original, w: 100)
      expect(url).to eq("https://example.com/cdn-cgi/image/width=100/#{original}")
    end

    it 'upgrades protocol-relative URLs to https' do
      url = cdn_image_url('//images.ctfassets.net/space/a/t/p.jpg', w: 100)
      expect(url).to eq('https://example.com/cdn-cgi/image/width=100/https://images.ctfassets.net/space/a/t/p.jpg')
    end

    it 'leaves an already-transformed URL alone' do
      transformed = 'https://example.com/cdn-cgi/image/width=50/https://images.ctfassets.net/s/a/t/p.jpg'
      expect(cdn_image_url(transformed, w: 100)).to eq(transformed)
    end

    it "swaps in the asset's canonical URL when the id is known" do
      @assets = [OpenStruct.new(sys: OpenStruct.new(id: 'asset-1'), url: 'https://cdn.example.com/canonical.jpg')]
      expect(cdn_image_url(original, w: 10)).to eq('https://example.com/cdn-cgi/image/width=10/https://cdn.example.com/canonical.jpg')
    end

    # The whole point of the hard requirement: this used to resize via Contentful instead, which
    # looked identical in the browser and drained Contentful's bandwidth until someone noticed.
    context 'when IMAGES_URL is unset' do
      before { stub_env(images_url: nil) }

      it 'raises rather than silently falling back to Contentful resizing' do
        expect { cdn_image_url(original, w: 100) }.to raise_error(ImageHelpers::ImagesUrlMissing, /IMAGES_URL is unset/)
      end

      it 'still returns nil for a blank URL, so a missing logo is not a misconfiguration' do
        expect(cdn_image_url(nil)).to be_nil
      end

      it 'still passes an already-transformed URL through without needing the host' do
        transformed = 'https://example.com/cdn-cgi/image/width=50/https://images.ctfassets.net/s/a/t/p.jpg'
        expect(cdn_image_url(transformed, w: 100)).to eq(transformed)
      end
    end
  end

  describe '#contentful_image_url' do
    let(:original) { 'https://images.ctfassets.net/space/asset-1/token/photo.jpg' }

    it 'translates fit=cover to fit=fill' do
      expect(contentful_image_url(original, fit: 'cover')).to eq("#{original}?fit=fill")
    end

    it 'drops fm=auto, which Contentful has no equivalent for' do
      expect(contentful_image_url(original, fm: 'auto', w: 100)).to eq("#{original}?w=100")
    end

    it "doesn't mutate the caller's params" do
      params = { fit: 'cover', fm: 'auto' }
      contentful_image_url(original, params)
      expect(params).to eq({ fit: 'cover', fm: 'auto' })
    end
  end

  describe '#srcset' do
    it 'renders a width-described candidate per size' do
      set = srcset(url: 'https://images.ctfassets.net/s/a/t/p.jpg', widths: [100, 200])
      expect(set).to eq(
        'https://example.com/cdn-cgi/image/width=100/https://images.ctfassets.net/s/a/t/p.jpg 100w, ' \
        'https://example.com/cdn-cgi/image/width=200/https://images.ctfassets.net/s/a/t/p.jpg 200w'
      )
    end

    it 'crops square when asked' do
      set = srcset(url: 'https://images.ctfassets.net/s/a/t/p.jpg', widths: [100], square: true)
      expect(set).to include('width=100')
      expect(set).to include('height=100')
      expect(set).to include('fit=cover')
    end
  end

  describe '#open_graph_image_url' do
    it "uses Facebook's card dimensions" do
      url = open_graph_image_url('https://images.ctfassets.net/s/a/t/p.jpg')
      expect(url).to include('width=1200')
      expect(url).to include('height=630')
    end

    # Centre-cropped on purpose. gravity=auto was tried and reverted: its saliency crops were
    # too unpredictable on these photos.
    it 'centre-crops on Cloudflare, asking for no gravity' do
      url = open_graph_image_url('https://images.ctfassets.net/s/a/t/p.jpg')
      expect(url).to eq(
        'https://example.com/cdn-cgi/image/width=1200,height=630,fit=cover/' \
        'https://images.ctfassets.net/s/a/t/p.jpg'
      )
    end
  end

  describe '#get_asset_id edge cases' do
    it 'is nil for a URL with fewer than five path segments' do
      expect(get_asset_id('https://example.com/a.jpg')).to be_nil
    end
  end

  describe 'asset lookup edge cases' do
    it 'returns nil description when the asset has none' do
      @assets = [OpenStruct.new(sys: OpenStruct.new(id: 'asset-1'), description: nil)]
      expect(get_asset_description('asset-1')).to be_nil
    end

    it 'returns nils for content type, URL, and published version of an unknown asset' do
      expect(get_asset_content_type('nope')).to be_nil
      expect(get_asset_url('nope')).to be_nil
      expect(get_asset_published_version('nope')).to be_nil
    end
  end

  # Cloudflare branch, exact output pinned. Cloudflare puts its options in the path, so the
  # option order, their names (width/height/format/fit, not w/h/fm), and the fact that the
  # source URL is appended raw all have to survive a refactor unchanged.
  describe '#cdn_image_url exact Cloudflare output' do
    let(:source) { 'https://images.ctfassets.net/space/asset-1/token/photo.jpg' }

    before { stub_env(images_url: 'https://example.com') }

    it 'pins the option order, and renames fm=jpg to format=jpeg' do
      url = cdn_image_url(source, w: 100, h: 50, fm: 'jpg', fit: 'cover')
      expect(url).to eq("https://example.com/cdn-cgi/image/format=jpeg,width=100,height=50,fit=cover/#{source}")
    end

    it 'passes fm=auto through as format=auto, so Cloudflare negotiates the format' do
      url = cdn_image_url(source, fm: 'auto', w: 100)
      expect(url).to eq("https://example.com/cdn-cgi/image/format=auto,width=100/#{source}")
    end

    # Cloudflare rejects a URL with no options, and anim=true is its default — so this is how a
    # params-less caller asks for the image untransformed. Emitting no format here is what keeps
    # gifs animated and preserves transparency; don't "tidy" it into format=auto.
    it 'falls back to anim=true when there are no params, transforming nothing' do
      url = cdn_image_url(source)
      expect(url).to eq("https://example.com/cdn-cgi/image/anim=true/#{source}")
    end

    it 'pins the exact output for a protocol-relative source URL' do
      url = cdn_image_url('//images.ctfassets.net/space/asset-1/token/photo.jpg', w: 50)
      expect(url).to eq("https://example.com/cdn-cgi/image/width=50/#{source}")
    end

    # The candidates are joined with ", " — commas also separate Cloudflare's options, so the
    # space is what keeps the srcset parseable. Don't join with a bare comma.
    it 'builds a srcset whose candidates stay distinguishable from the option commas' do
      set = srcset(url: source, widths: [100, 200], options: { fm: 'auto' })
      expect(set).to eq(
        "https://example.com/cdn-cgi/image/format=auto,width=100/#{source} 100w, " \
        "https://example.com/cdn-cgi/image/format=auto,width=200/#{source} 200w"
      )
    end
  end

  describe '#site_icon_url' do
    context 'when the site has a logo' do
      def data
        OpenStruct.new(
          assets: [],
          site: OpenStruct.new(logo: OpenStruct.new(url: 'https://images.ctfassets.net/space/logo-1/token/logo.png'))
        )
      end

      it 'returns the CDN URL for the logo at the requested width' do
        expect(site_icon_url(w: 32)).to eq(
          'https://example.com/cdn-cgi/image/width=32/https://images.ctfassets.net/space/logo-1/token/logo.png'
        )
      end

      # The rescue below exists for a site entry with no logo. It must not also swallow a
      # misconfigured build into a silently missing icon.
      it 'lets a missing IMAGES_URL raise through its rescue' do
        stub_env(images_url: nil)
        expect { site_icon_url(w: 32) }.to raise_error(ImageHelpers::ImagesUrlMissing)
      end
    end

    context 'when the site has no logo' do
      it 'rescues the lookup failure and returns nil' do
        expect(site_icon_url(w: 32)).to be_nil
      end
    end
  end

  describe '#generate_open_graph_image_url' do
    def stub_og(url)
      allow(ENV).to receive(:[]).with('OG_IMAGE_URL').and_return(url)
    end

    it 'points at the kona-og service with the page url and a version cache buster' do
      stub_og('https://og.example.com')
      result = generate_open_graph_image_url('https://example.com/articles/foo/', 1082)
      parsed = URI.parse(result)
      expect("#{parsed.scheme}://#{parsed.host}#{parsed.path}").to eq('https://og.example.com/og.png')
      expect(URI.decode_www_form(parsed.query).to_h).to eq(
        'url' => 'https://example.com/articles/foo/',
        'v' => 'v1-1082'
      )
    end

    it 'trims a trailing slash on the configured base' do
      stub_og('https://og.example.com/')
      expect(generate_open_graph_image_url('https://example.com/', 7))
        .to start_with('https://og.example.com/og.png?')
    end

    it 'returns nil when OG_IMAGE_URL is unset (kona-og not wired up)' do
      stub_og(nil)
      expect(generate_open_graph_image_url('https://example.com/', 1)).to be_nil
    end
  end

  describe 'blurhash pipeline' do
    # A published 1600x900 JPEG; the 32px-wide blurhash thumb is 32x18.
    def asset(content_type: 'image/jpeg', published_version: 3)
      OpenStruct.new(
        sys: OpenStruct.new(id: 'asset-1', published_version: published_version),
        url: 'https://images.ctfassets.net/space/asset-1/token/photo.jpg',
        width: 1600, height: 900, content_type: content_type
      )
    end

    before { @assets = [asset] }

    describe '#blurhash_jpeg_data_uri' do
      let(:fake_redis) { double('redis', get: nil, set: nil) }
      let(:fake_image) { double('image', write_to_buffer: 'JPEGBYTES') }

      before do
        allow(self).to receive(:redis).and_return(fake_redis)
        allow(self).to receive(:encode_blurhash).with('asset-1', 32, 18).and_return('LEHV6nWB2yk8pyo0adR*.7kCMdnj')
        allow(Blurhash).to receive(:decode).and_return([0, 0, 0, 255])
        allow(fake_image).to receive(:copy).and_return(fake_image)
        allow(fake_image).to receive(:extract_band).and_return(fake_image)
        allow(Vips::Image).to receive(:new_from_memory).and_return(fake_image)
      end

      it 'decodes the blurhash into a JPEG and returns it as a base64 data URI' do
        expect(blurhash_jpeg_data_uri('asset-1')).to eq('data:image/jpeg;base64,SlBFR0JZVEVT')
      end

      it 'caches the data URI in Redis keyed by asset, published version, and width' do
        blurhash_jpeg_data_uri('asset-1')
        expect(fake_redis).to have_received(:set).with('blurhash:jpeg:asset-1:3:32', 'data:image/jpeg;base64,SlBFR0JZVEVT')
      end

      it 'returns the cached data URI without regenerating' do
        allow(fake_redis).to receive(:get).with('blurhash:jpeg:asset-1:3:32').and_return('data:image/jpeg;base64,cached')
        expect(blurhash_jpeg_data_uri('asset-1')).to eq('data:image/jpeg;base64,cached')
        expect(Vips::Image).not_to have_received(:new_from_memory)
      end

      it 'is nil for gifs' do
        @assets = [asset(content_type: 'image/gif')]
        expect(blurhash_jpeg_data_uri('asset-1')).to be_nil
      end

      it 'is nil when the asset has no published version' do
        @assets = [asset(published_version: nil)]
        expect(blurhash_jpeg_data_uri('asset-1')).to be_nil
      end

      it 'is nil when the blurhash string is invalid' do
        allow(self).to receive(:encode_blurhash).with('asset-1', 32, 18).and_return('not-a-blurhash')
        expect(blurhash_jpeg_data_uri('asset-1')).to be_nil
      end
    end

    describe '#encode_blurhash' do
      # Even on a deployed build, the thumbnail comes straight from Contentful — not from our own
      # zone. Routing it through Cloudflare would make the build depend on the zone being up, and
      # would spend a transformation on an image no visitor ever sees.
      it 'downloads the thumbnail from Contentful, not through the CDN' do
        stub_env(images_url: 'https://example.com')
        allow(URI).to receive(:open).and_raise(StandardError, 'stop here')
        allow(self).to receive(:warn)

        encode_blurhash('asset-1', 32, 18)

        expect(URI).to have_received(:open)
          .with('https://images.ctfassets.net/space/asset-1/token/photo.jpg?w=32&h=18')
      end
    end

    describe '#blurhash_svg' do
      it "embeds the blurhash JPEG in a blurred SVG sized to the asset's viewBox" do
        allow(self).to receive(:blurhash_jpeg_data_uri).with('asset-1').and_return('data:image/jpeg;base64,abc123')
        expect(blurhash_svg('asset-1')).to eq(
          "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' viewBox='0 0 1600 900'>\n" \
          "      <filter id='blur' filterUnits='userSpaceOnUse' color-interpolation-filters='sRGB'>\n" \
          "        <feGaussianBlur stdDeviation='100' edgeMode='duplicate' />\n" \
          "        <feComponentTransfer>\n" \
          "          <feFuncA type='discrete' tableValues='1 1' />\n" \
          "        </feComponentTransfer>\n" \
          "      </filter>\n" \
          "      <image filter='url(#blur)' xlink:href='data:image/jpeg;base64,abc123' x='0' y='0' height='100%' width='100%'/>\n" \
          "    </svg>"
        )
      end

      it 'is nil when the JPEG data URI cannot be generated' do
        allow(self).to receive(:blurhash_jpeg_data_uri).with('asset-1').and_return(nil)
        expect(blurhash_svg('asset-1')).to be_nil
      end
    end

    describe '#blurhash_svg_data_uri' do
      it 'collapses whitespace and percent-encodes the SVG into a data URI' do
        allow(self).to receive(:blurhash_svg).with('asset-1').and_return("<svg>  <g/>\n</svg>")
        expect(blurhash_svg_data_uri('asset-1')).to eq('data:image/svg+xml;charset=utf-8,%3Csvg%3E%20%3Cg%2F%3E%20%3C%2Fsvg%3E')
      end

      it 'is nil when there is no SVG' do
        allow(self).to receive(:blurhash_svg).with('asset-1').and_return(nil)
        expect(blurhash_svg_data_uri('asset-1')).to be_nil
      end
    end
  end
end
