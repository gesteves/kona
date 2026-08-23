require 'spec_helper'
require 'ostruct'
require 'yaml'
# `tag` comes from Padrino, which Middleman gives to a template but not to an example group.
require 'padrino-helpers'

RSpec.describe ImageHelpers do
  # This has the shape of data.assets. Each example sets @assets before the code makes the index.
  def data = OpenStruct.new(assets: @assets || [])

  # IMAGES_URL is the host that Cloudflare serves each transformation from, and each environment
  # needs it. There is no fallback to a Contentful resize, thus no value means a raise. No code
  # here reads CONTEXT or URL. The default is a value, because that is each environment that the
  # code supports.
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
      expect(get_asset_dimensions('asset-1')).to eq([ 1600, 900 ])
      expect(get_asset_description('asset-1')).to eq('A finish line')
      expect(get_asset_content_type('asset-1')).to eq('image/jpeg')
      expect(get_asset_url('asset-1')).to eq('https://images.ctfassets.net/space/asset-1/token/photo.jpg')
      expect(get_asset_published_version('asset-1')).to eq(7)
    end

    it 'returns nils for an unknown asset' do
      expect(get_asset_dimensions('nope')).to eq([ nil, nil ])
      expect(get_asset_description('nope')).to be_nil
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
      @assets = [ OpenStruct.new(sys: OpenStruct.new(id: 'asset-1'), url: 'https://cdn.example.com/canonical.jpg') ]
      expect(cdn_image_url(original, w: 10)).to eq('https://example.com/cdn-cgi/image/width=10/https://cdn.example.com/canonical.jpg')
    end

    # This is why the value is necessary: the code resized with Contentful, which looked the same
    # in the browser and used the Contentful bandwidth until a person found it.
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

  describe '#srcset' do
    it 'renders a width-described candidate per size' do
      set = srcset(url: 'https://images.ctfassets.net/s/a/t/p.jpg', widths: [ 100, 200 ])
      expect(set).to eq(
        'https://example.com/cdn-cgi/image/width=100/https://images.ctfassets.net/s/a/t/p.jpg 100w, ' \
        'https://example.com/cdn-cgi/image/width=200/https://images.ctfassets.net/s/a/t/p.jpg 200w'
      )
    end

    it 'crops to a square with ratio 1' do
      set = srcset(url: 'https://images.ctfassets.net/s/a/t/p.jpg', widths: [ 100 ], ratio: 1)
      expect(set).to include('width=100')
      expect(set).to include('height=100')
      expect(set).to include('fit=cover')
    end

    it 'crops to 3:2 with the card ratio' do
      set = srcset(url: 'https://images.ctfassets.net/s/a/t/p.jpg', widths: [ 600 ], ratio: ImageHelpers::CARD_RATIO)
      expect(set).to include('width=600')
      expect(set).to include('height=400')
      expect(set).to include('fit=cover')
    end
  end

  describe '#open_graph_image_url' do
    it "uses Facebook's card dimensions" do
      url = open_graph_image_url('https://images.ctfassets.net/s/a/t/p.jpg')
      expect(url).to include('width=1200')
      expect(url).to include('height=630')
    end

    # The code cuts the image at the center, on purpose. gravity=auto gave saliency crops that were
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
      @assets = [ OpenStruct.new(sys: OpenStruct.new(id: 'asset-1'), description: nil) ]
      expect(get_asset_description('asset-1')).to be_nil
    end

    it 'returns nils for content type, URL, and published version of an unknown asset' do
      expect(get_asset_content_type('nope')).to be_nil
      expect(get_asset_url('nope')).to be_nil
      expect(get_asset_published_version('nope')).to be_nil
    end
  end

  # The Cloudflare code, with the exact output. Cloudflare puts its options in the path. Thus the
  # order of the options, their names (width, height, format, and fit, and not w, h, and fm), and
  # the source URL at the end with no change must all stay the same after a change to the code.
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

    # Cloudflare refuses a URL with no options, and anim=true is its default. Thus this is how a
    # caller with no parameters asks for the image with no transformation. No format here is what
    # keeps a gif animated and keeps the transparency. Do not change it to format=auto.
    it 'falls back to anim=true when there are no params, transforming nothing' do
      url = cdn_image_url(source)
      expect(url).to eq("https://example.com/cdn-cgi/image/anim=true/#{source}")
    end

    it 'pins the exact output for a protocol-relative source URL' do
      url = cdn_image_url('//images.ctfassets.net/space/asset-1/token/photo.jpg', w: 50)
      expect(url).to eq("https://example.com/cdn-cgi/image/width=50/#{source}")
    end

    # A ", " goes between the candidates. A comma also goes between the Cloudflare options, thus
    # the space is what lets a parser read the srcset. Do not use a comma alone.
    it 'builds a srcset whose candidates stay distinguishable from the option commas' do
      set = srcset(url: source, widths: [ 100, 200 ], options: { fm: 'auto' })
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

      # The rescue below exists for a site entry with no logo. It must not also change a build with
      # an incorrect configuration into an icon that is absent with no message.
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
    # root_url is in UrlHelpers, and RSpec includes only ImageHelpers here. The Worker of the site
    # serves the card route, thus this is the only host.
    def root_url = @root_url || 'https://example.com'

    # The card URL comes from the path of the page. Thus the Worker can find the page from the
    # request path, and not from a ?path= parameter. Refer to web/src/og.ts.
    it 'hangs the card off the page’s own path, with a version cache buster' do
      result = generate_open_graph_image_url('/articles/foo/', 1082)
      parsed = URI.parse(result)
      expect("#{parsed.scheme}://#{parsed.host}#{parsed.path}")
        .to eq('https://example.com/articles/foo/og.png')
      expect(URI.decode_www_form(parsed.query).to_h).to eq('v' => 'v1-1082')
    end

    it 'serves the home page’s card from the root' do
      expect(generate_open_graph_image_url('/', 7))
        .to eq('https://example.com/og.png?v=v1-7')
    end

    it 'trims a trailing slash on root_url' do
      @root_url = 'https://example.com/'
      expect(generate_open_graph_image_url('/', 7))
        .to eq('https://example.com/og.png?v=v1-7')
    end

    it 'busts on OG_TEMPLATE_VERSION alone when version is nil (listing pages have no sys)' do
      result = generate_open_graph_image_url('/blog/', nil)
      expect(result).to eq('https://example.com/blog/og.png?v=v1')
    end
  end

  describe 'blurhash pipeline' do
    # A published JPEG of 1600x900. The blurhash thumbnail at 32px wide is 32x18.
    def asset(content_type: 'image/jpeg', published_version: 3)
      OpenStruct.new(
        sys: OpenStruct.new(id: 'asset-1', published_version: published_version),
        url: 'https://images.ctfassets.net/space/asset-1/token/photo.jpg',
        width: 1600, height: 900, content_type: content_type
      )
    end

    before { @assets = [ asset ] }

    describe '#blurhash_jpeg_data_uri' do
      let(:fake_redis) { double('redis', get: nil, set: nil) }
      let(:fake_image) { double('image', write_to_buffer: 'JPEGBYTES') }

      before do
        allow(self).to receive(:redis).and_return(fake_redis)
        allow(self).to receive(:encode_blurhash).with('asset-1', 32, 18).and_return('LEHV6nWB2yk8pyo0adR*.7kCMdnj')
        # ⚠️ This does NOT stub Blurhash.decode, on purpose. It is Ruby only, and a 32x18 decode
        # takes less than a millisecond. A stub that returns a flat array is what hid the TypeError
        # from `pixels.pack('C*')` on the true nested [row][col][r,g,b,a] output of decode. Each
        # cache miss then gave no placeholder for weeks. Use the true shape.
        allow(fake_image).to receive(:copy).and_return(fake_image)
        allow(fake_image).to receive(:extract_band).and_return(fake_image)
        allow(Vips::Image).to receive(:new_from_memory).and_return(fake_image)
      end

      it 'decodes the blurhash into a JPEG and returns it as a base64 data URI' do
        expect(blurhash_jpeg_data_uri('asset-1')).to eq('data:image/jpeg;base64,SlBFR0JZVEVT')
      end

      it 'flattens the decoded pixels before packing them into the vips buffer' do
        blurhash_jpeg_data_uri('asset-1')
        # 32x18 RGBA, with one byte for each band. A pack of the nested array raises TypeError.
        expect(Vips::Image).to have_received(:new_from_memory)
          .with(satisfy { |buffer| buffer.bytesize == 32 * 18 * 4 }, 32, 18, 4, :uchar)
      end

      it 'caches the data URI in Redis keyed by asset, published version, and width' do
        blurhash_jpeg_data_uri('asset-1')
        expect(fake_redis).to have_received(:set)
          .with('blurhash:jpeg:asset-1:3:32', 'data:image/jpeg;base64,SlBFR0JZVEVT', ex: ImageHelpers::BLURHASH_CACHE_TTL)
      end

      it 'returns the cached data URI without regenerating' do
        allow(fake_redis).to receive(:get).with('blurhash:jpeg:asset-1:3:32').and_return('data:image/jpeg;base64,cached')
        expect(blurhash_jpeg_data_uri('asset-1')).to eq('data:image/jpeg;base64,cached')
        expect(Vips::Image).not_to have_received(:new_from_memory)
      end

      it 'is nil for gifs' do
        @assets = [ asset(content_type: 'image/gif') ]
        expect(blurhash_jpeg_data_uri('asset-1')).to be_nil
      end

      it 'is nil when the asset has no published version' do
        @assets = [ asset(published_version: nil) ]
        expect(blurhash_jpeg_data_uri('asset-1')).to be_nil
      end

      it 'is nil when the blurhash string is invalid' do
        allow(self).to receive(:encode_blurhash).with('asset-1', 32, 18).and_return('not-a-blurhash')
        expect(blurhash_jpeg_data_uri('asset-1')).to be_nil
      end
    end

    describe '#encode_blurhash' do
      # Cloudflare resizes the thumbnail, as it resizes each other image on the site. The code went
      # to the Contentful Images API to save a transformation, but a transformation costs a small
      # part of a cent and the Contentful asset bandwidth is what has a meter.
      it 'resizes the thumbnail through Cloudflare Images' do
        stub_env(images_url: 'https://example.com')
        allow(URI).to receive(:open).and_raise(StandardError, 'stop here')
        allow(self).to receive(:warn)

        encode_blurhash('asset-1', 32, 18)

        expect(URI).to have_received(:open).with(
          'https://example.com/cdn-cgi/image/format=jpeg,width=32,height=18/' \
          'https://images.ctfassets.net/space/asset-1/token/photo.jpg',
          open_timeout: ImageHelpers::BLURHASH_OPEN_TIMEOUT,
          read_timeout: ImageHelpers::BLURHASH_READ_TIMEOUT
        )
      end

      # The mirror URL is the correct source here: Cloudflare gets it from inside the zone, and the
      # resize is in the path. Thus no code needs the source to read a query string. R2 ignores a
      # query string, and that is why this code could not use the mirror before.
      it 'sources the thumbnail from the R2 mirror when the rewrite is on' do
        @assets = [
          OpenStruct.new(
            sys: OpenStruct.new(id: 'asset-1', published_version: 3),
            url: 'https://images.example.com/space/asset-1/token/photo.jpg',
            width: 1600, height: 900, content_type: 'image/jpeg'
          )
        ]
        stub_env(images_url: 'https://example.com')
        allow(URI).to receive(:open).and_raise(StandardError, 'stop here')
        allow(self).to receive(:warn)

        encode_blurhash('asset-1', 32, 18)

        expect(URI).to have_received(:open).with(
          'https://example.com/cdn-cgi/image/format=jpeg,width=32,height=18/' \
          'https://images.example.com/space/asset-1/token/photo.jpg',
          open_timeout: ImageHelpers::BLURHASH_OPEN_TIMEOUT,
          read_timeout: ImageHelpers::BLURHASH_READ_TIMEOUT
        )
      end

      # Nothing renders without IMAGES_URL, but the rescue here would change that into a loss of
      # the placeholders with no message, and cdn_image_url exists to give a failure with a
      # message.
      it 'warns and returns nil when IMAGES_URL is unset' do
        stub_env(images_url: nil)
        allow(self).to receive(:warn)

        expect(encode_blurhash('asset-1', 32, 18)).to be_nil
        expect(self).to have_received(:warn).with(/IMAGES_URL is unset/)
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

  describe '#cover_image_tag' do
    include Padrino::Helpers::TagHelpers

    # The true variants, thus the example fails when a person removes the `card` variant or
    # changes its first width.
    let(:srcsets) { OpenStruct.new(YAML.load_file('data/srcsets.yml').transform_values { |v| OpenStruct.new(v) }) }

    def data = OpenStruct.new(assets: @assets || [], srcsets: srcsets)

    def entry(url: 'https://images.ctfassets.net/space/asset-1/token/photo.jpg')
      OpenStruct.new(cover_image: url && OpenStruct.new(url: url, width: 3000, height: 2000))
    end

    before do
      @assets = [
        OpenStruct.new(
          sys: OpenStruct.new(id: 'asset-1', published_version: 7),
          url: 'https://images.ctfassets.net/space/asset-1/token/photo.jpg',
          width: 3000, height: 2000, description: 'A finish line', content_type: 'image/jpeg'
        )
      ]
      allow(self).to receive(:blurhash_svg_data_uri).and_return(nil)
    end

    it 'renders the card size, an empty alt, and the placeholder attributes' do
      html = cover_image_tag(entry)

      expect(html).to include('width="592"')
      expect(html).to include('height="395"')
      expect(html).to include('alt=""')
      expect(html).to include('loading="lazy"')
      expect(html).to include('decoding="async"')
      expect(html).to include('class="entry__cover-image placeholder"')
      expect(html).to include('data-controller="image-placeholder"')
    end

    it 'cuts each candidate to 3:2' do
      html = cover_image_tag(entry)

      expect(html).to include('width=592,height=395,fit=cover')
      expect(html).to include('width=1184,height=789,fit=cover')
    end

    # ⚠️ Cloudflare renders and bills one transformation for each different URL. A src with
    # parameters that only look the same is a second render of each cover image that no browser
    # uses.
    it 'uses one of its own srcset candidates as the src' do
      html = cover_image_tag(entry).to_s
      src = html[/\ssrc="([^"]+)"/, 1]
      candidates = html[/srcset="([^"]+)"/, 1].split(', ').map { |c| c.split(' ').first }

      expect(candidates).to include(src)
    end

    it 'gives a GIF a src with no transformation, thus it keeps its animation' do
      @assets.first.content_type = 'image/gif'

      expect(cover_image_tag(entry)).to include('/cdn-cgi/image/anim=true/')
    end

    it 'removes each candidate that is wider than the asset' do
      @assets.first.width = 700
      html = cover_image_tag(OpenStruct.new(cover_image: OpenStruct.new(url: @assets.first.url, width: 700, height: 500)))

      expect(html).to include('700w')
      expect(html).not_to include('1184w')
    end

    it 'gives a GIF no srcset, because a transformation removes its animation' do
      @assets.first.content_type = 'image/gif'
      html = cover_image_tag(entry)

      expect(html).not_to include('srcset')
      expect(html).not_to include('sizes')
    end

    it 'writes the blurhash placeholder as a custom property' do
      allow(self).to receive(:blurhash_svg_data_uri).and_return('data:image/svg+xml,x')

      expect(cover_image_tag(entry)).to include('--placeholder:url(')
    end

    it 'is an empty string when the entry has no cover image' do
      expect(cover_image_tag(entry(url: nil))).to eq('')
      expect(cover_image_tag(nil)).to eq('')
    end
  end
end
