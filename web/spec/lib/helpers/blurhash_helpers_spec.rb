require 'spec_helper'
require 'ostruct'

RSpec.describe BlurhashHelpers do
  def data = OpenStruct.new(assets: @assets || [])

  # The thumbnail of a placeholder comes through Cloudflare Images, thus it needs IMAGES_URL.
  def stub_env(images_url: 'https://example.com')
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('IMAGES_URL').and_return(images_url)
  end

  before { stub_env }

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
      let(:fake_image) { double('image', jpegsave_buffer: 'JPEGBYTES') }

      before do
        allow(self).to receive(:redis).and_return(fake_redis)
        allow(self).to receive(:encode_blurhash).with('asset-1', 32, 18).and_return('LEHV6nWB2yk8pyo0adR*.7kCMdnj')
        # ⚠️ This does NOT stub Blurhash.decode, on purpose. The true decode returns a nested
        # [row][col][r,g,b,a] array, and `pixels.pack('C*')` raises TypeError on it. A stub that
        # returns a flat array hides that fault, and each cache miss then gives no placeholder.
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
          .with('blurhash:jpeg:asset-1:3:32', 'data:image/jpeg;base64,SlBFR0JZVEVT', ex: BlurhashHelpers::BLURHASH_CACHE_TTL)
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
      # Cloudflare resizes the thumbnail, as it resizes each other image on the site. A resize by
      # Contentful would use the metered asset bandwidth.
      it 'resizes the thumbnail through Cloudflare Images' do
        stub_env(images_url: 'https://example.com')
        allow(URI).to receive(:open).and_raise(StandardError, 'stop here')
        allow(self).to receive(:warn)

        encode_blurhash('asset-1', 32, 18)

        expect(URI).to have_received(:open).with(
          'https://example.com/cdn-cgi/image/format=jpeg,width=32,height=18/' \
          'https://images.ctfassets.net/space/asset-1/token/photo.jpg',
          open_timeout: BlurhashHelpers::BLURHASH_OPEN_TIMEOUT,
          read_timeout: BlurhashHelpers::BLURHASH_READ_TIMEOUT
        )
      end

      # The mirror URL is the correct source here: Cloudflare gets it from inside the zone, and the
      # resize is in the path. Thus the source does not need to read a query string. R2 ignores one.
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
          open_timeout: BlurhashHelpers::BLURHASH_OPEN_TIMEOUT,
          read_timeout: BlurhashHelpers::BLURHASH_READ_TIMEOUT
        )
      end

      # The rescue of encode_blurhash also catches ImagesUrlMissing. Thus the warning must name
      # IMAGES_URL, or the placeholders go away with no message.
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
        # `/` stays: it is legal in a url(), and a listing page holds one placeholder for each card.
        expect(blurhash_svg_data_uri('asset-1')).to eq('data:image/svg+xml;charset=utf-8,%3Csvg%3E%20%3Cg/%3E%20%3C/svg%3E')
      end

      # ⚠️ The caller puts this value in `url('...')`, thus a raw `'` closes that CSS string and
      # the browser paints no placeholder. A raw quote also makes `minify_html` read the SVG
      # attributes as HTML attributes and remove some of their quotes. Use the TRUE output of
      # `blurhash_svg` here: a fixture with no attribute hides this fault.
      it 'percent-encodes each quote, thus the value cannot close the CSS string' do
        allow(self).to receive(:blurhash_jpeg_data_uri).with('asset-1').and_return('data:image/jpeg;base64,abc123')

        uri = blurhash_svg_data_uri('asset-1')

        expect(uri).not_to include("'")
        expect(uri).not_to include('"')
        expect(uri).to include('xmlns=%27http://www.w3.org/2000/svg%27')
      end

      it 'is nil when there is no SVG' do
        allow(self).to receive(:blurhash_svg).with('asset-1').and_return(nil)
        expect(blurhash_svg_data_uri('asset-1')).to be_nil
      end
    end
  end

  describe '.warm_blurhashes!' do
    before { BlurhashHelpers.warm_blurhashes.clear }
    after { BlurhashHelpers.warm_blurhashes.clear }

    def asset(id, version) = OpenStruct.new(sys: OpenStruct.new(id: id, published_version: version))

    # ⚠️ The build renders in forked workers, and each one would ask Redis for each asset again.
    # This reads every placeholder in one call, in the parent, before the fork.
    it 'reads each placeholder in one call and keeps the hits by asset and width' do
      redis = instance_double(Redis)
      allow(redis).to receive(:mget).with('blurhash:jpeg:a1:3:32', 'blurhash:jpeg:a2:1:32').and_return([ 'data:image/jpeg;base64,AAAA', nil ])

      found = BlurhashHelpers.warm_blurhashes!([ asset('a1', 3), asset('a2', 1) ], redis)

      expect(found).to eq(1)
      expect(BlurhashHelpers.warm_blurhashes).to eq([ 'a1', 32 ] => 'data:image/jpeg;base64,AAAA')
    end

    it 'skips an asset with no id or no published version, and asks nothing for an empty list' do
      redis = instance_double(Redis)
      allow(redis).to receive(:mget)

      expect(BlurhashHelpers.warm_blurhashes!([ asset(nil, 3), asset('a3', nil) ], redis)).to eq(0)
      expect(redis).not_to have_received(:mget)
    end
  end
end
