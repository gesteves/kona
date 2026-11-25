require 'spec_helper'

RSpec.describe MarkupImageHelpers do
  include Padrino::Helpers
  include Padrino::Helpers::TagHelpers

  describe '#set_caption_credit' do
    context 'when given a figcaption with a separator' do
      it 'wraps the credit in a cite tag' do
        html = '<figcaption>This is a caption | Photo by Pepe</figcaption>'
        transformed_html = set_caption_credit(html)
        expect(transformed_html).to eq('<figcaption>This is a caption <cite>Photo by Pepe</cite></figcaption>')
      end

      it 'preserves HTML tags in the caption' do
        html = '<figcaption>This is <a href="http://example.com">a link</a> | Photo by Pepe</figcaption>'
        transformed_html = set_caption_credit(html)
        expect(transformed_html).to eq('<figcaption>This is <a href="http://example.com">a link</a> <cite>Photo by Pepe</cite></figcaption>')
      end

      it 'preserves HTML tags in the credit' do
        html = '<figcaption>This is a caption | Photo by <a href="http://example.com">Pepe</a></figcaption>'
        transformed_html = set_caption_credit(html)
        expect(transformed_html).to eq('<figcaption>This is a caption <cite>Photo by <a href="http://example.com">Pepe</a></cite></figcaption>')
      end

      it 'ignores | characters in HTML attributes' do
        html = '<figcaption>This is <a href="http://example.com" title="example | page">a link</a> | Photo by Pepe</figcaption>'
        transformed_html = set_caption_credit(html)
        expect(transformed_html).to eq('<figcaption>This is <a href="http://example.com" title="example | page">a link</a> <cite>Photo by Pepe</cite></figcaption>')
      end

      # A split on the text content of an element puts plain text nodes in its place. Thus a full
      # caption that is one link would lose that link.
      it 'does not split inside an element, dropping its markup' do
        html = '<figcaption><a href="http://example.com">Ride report | Strava</a></figcaption>'
        transformed_html = set_caption_credit(html)
        expect(transformed_html).to eq(html)
      end
    end

    context 'when given a figcaption without a separator' do
      it 'leaves the content unchanged' do
        html = '<figcaption>This is a caption without a credit</figcaption>'
        transformed_html = set_caption_credit(html)
        expect(transformed_html).to eq(html)
      end

      it 'leaves the content unchanged even with | in attributes' do
        html = '<figcaption>This is <a href="http://example.com" title="example | page">a link</a></figcaption>'
        transformed_html = set_caption_credit(html)
        expect(transformed_html).to eq(html)
      end
    end

    context 'when given multiple figcaptions' do
      it 'processes each figcaption independently' do
        html = '<div><figcaption>First caption | First credit</figcaption><figcaption>Second caption | Second credit</figcaption></div>'
        transformed_html = set_caption_credit(html)
        expect(transformed_html).to include(
          '<figcaption>First caption <cite>First credit</cite></figcaption>',
          '<figcaption>Second caption <cite>Second credit</cite></figcaption>'
        )
      end
    end
  end

  describe '#wrap_figcaption_emoji' do
    context 'when given a figcaption with emojis' do
      it 'wraps single emoji in <span class="emoji"> tags' do
        html = '<figcaption>Amazing sunset 📸</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq('<figcaption>Amazing sunset <span class="emoji">📸</span></figcaption>')
      end

      it 'wraps multiple emojis in separate <span class="emoji"> tags' do
        html = '<figcaption>Great shot 📷 with perfect lighting ✨</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq('<figcaption>Great shot <span class="emoji">📷</span> with perfect lighting <span class="emoji">✨</span></figcaption>')
      end

      it 'wraps emojis while preserving other HTML tags' do
        html = '<figcaption>Amazing <a href="http://example.com">photo</a> 🎨 | Photo by <cite>Artist</cite> 📸</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq('<figcaption>Amazing <a href="http://example.com">photo</a> <span class="emoji">🎨</span> | Photo by <cite>Artist</cite> <span class="emoji">📸</span></figcaption>')
      end

      it 'handles consecutive emojis in a single span' do
        html = '<figcaption>Fantastic view 🌟✨🎯</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq('<figcaption>Fantastic view <span class="emoji">🌟✨🎯</span></figcaption>')
      end

      it 'works with different emoji categories including variation selectors' do
        html = '<figcaption>Perfect day 😎☀️🌈</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq('<figcaption>Perfect day <span class="emoji">😎☀️🌈</span></figcaption>')
      end

      it 'handles emoji separated by spaces in a single span' do
        html = '<figcaption>Great shot 📷 ✨ 🎯</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq('<figcaption>Great shot <span class="emoji">📷 ✨ 🎯</span></figcaption>')
      end

      # ⚠️ The text of a caption is plain text. A parse of it as HTML would make an element from a
      # "<", and the words after it would go away.
      it 'keeps markup-like text as text' do
        html = '<figcaption>Under &lt;2:30 &lt;b&gt;today&lt;/b&gt; 😀</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq('<figcaption>Under &lt;2:30 &lt;b&gt;today&lt;/b&gt; <span class="emoji">😀</span></figcaption>')
      end
    end

    context 'when given a figcaption without emojis' do
      it 'leaves the content unchanged' do
        html = '<figcaption>This is a regular caption</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq(html)
      end

      it 'preserves HTML tags without emojis' do
        html = '<figcaption>Regular <a href="http://example.com">caption</a> with <strong>formatting</strong></figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq(html)
      end
    end

    context 'when given multiple figcaptions' do
      it 'processes each figcaption independently' do
        html = '<div><figcaption>First caption 📸</figcaption><figcaption>Second caption ✨</figcaption></div>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to include(
          '<figcaption>First caption <span class="emoji">📸</span></figcaption>',
          '<figcaption>Second caption <span class="emoji">✨</span></figcaption>'
        )
      end
    end

    context 'when html is blank' do
      it 'returns nil' do
        expect(wrap_figcaption_emoji('')).to be_nil
        expect(wrap_figcaption_emoji(nil)).to be_nil
      end
    end
  end

  describe '#add_image_data_attributes' do
    it 'stamps each image with its asset id and original URL' do
      html = '<p><img src="https://images.ctfassets.net/space/asset-1/token/photo.jpg"></p>'
      transformed_html = add_image_data_attributes(html)
      expect(transformed_html).to eq('<p><img src="https://images.ctfassets.net/space/asset-1/token/photo.jpg" data-asset-id="asset-1" data-original-url="https://images.ctfassets.net/space/asset-1/token/photo.jpg"></p>')
    end

    it 'stamps a blank asset id for URLs that do not follow the Contentful path shape' do
      html = '<p><img src="/images/local.jpg"></p>'
      transformed_html = add_image_data_attributes(html)
      expect(transformed_html).to eq('<p><img src="/images/local.jpg" data-asset-id="" data-original-url="/images/local.jpg"></p>')
    end
  end

  describe '#add_figure_elements_to_images' do
    let(:image_url) { 'https://images.ctfassets.net/space/asset-1/token/photo.jpg' }

    before do
      allow(self).to receive(:get_asset_content_type).with('asset-1').and_return('image/jpeg')
    end

    context 'with a base class' do
      it 'replaces the paragraph with a figure carrying the base and content-type modifier classes, and moves the caption into a figcaption' do
        html = %(<p><img src="#{image_url}">A caption | Credit</p>)
        transformed_html = add_figure_elements_to_images(html, base_class: 'entry')
        expect(transformed_html).to eq(%(<figure class="entry__figure entry__figure--jpeg"><img src="#{image_url}"><figcaption>A caption | Credit</figcaption></figure>))
      end
    end

    context 'without a base class' do
      it 'wraps the image in a bare figure and omits the figcaption when there is no caption' do
        html = %(<p><img src="#{image_url}"></p>)
        transformed_html = add_figure_elements_to_images(html)
        expect(transformed_html).to eq(%(<figure><img src="#{image_url}"></figure>))
      end
    end

    # The transform puts the other content of the parent into the caption and then replaces the
    # parent. Thus a second image in the same paragraph would go into the <figcaption> of the first
    # image, and the loop would then remove it from the tree.
    context 'with two images in one paragraph' do
      it 'leaves them alone rather than swallowing the second into the first figcaption' do
        html = %(<p><img src="#{image_url}"><img src="#{image_url}"></p>)
        transformed_html = add_figure_elements_to_images(html, base_class: 'entry')

        expect(transformed_html).to eq(html)
        expect(transformed_html).not_to include('figcaption')
      end
    end

    context 'when the asset has no known content type' do
      # For example, an image from another site, which is not a Contentful asset: it has no
      # content-type modifier and only the base class.
      it 'wraps the image in a figure with only the base figure class' do
        allow(self).to receive(:get_asset_content_type).and_return(nil)
        html = %(<p><img src="#{image_url}"></p>)
        expect(add_figure_elements_to_images(html, base_class: 'entry')).to eq(%(<figure class="entry__figure"><img src="#{image_url}"></figure>))
      end

      it 'still wraps the image when no base class is given' do
        allow(self).to receive(:get_asset_content_type).and_return(nil)
        html = %(<p><img src="#{image_url}"></p>)
        expect(add_figure_elements_to_images(html)).to eq(%(<figure><img src="#{image_url}"></figure>))
      end
    end
  end

  describe '#responsivize_images' do
    let(:image_url) { 'https://images.ctfassets.net/space/asset-1/token/photo.jpg' }
    let(:tagged_img) { %(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}">) }

    before do
      # A replacement for the CDN URL method that always gives the same result: it puts the
      # parameters at the end as a query string.
      allow(self).to receive(:cdn_image_url) do |url, params = {}|
        params.nil? || params.empty? ? url : "#{url}?#{URI.encode_www_form(params)}"
      end
      allow(self).to receive(:get_asset_dimensions).with('asset-1').and_return([ 200, 100 ])
      allow(self).to receive(:get_asset_content_type).with('asset-1').and_return('image/jpeg')
    end

    # There is no <picture> and no <source> for each format. There is one srcset with format=auto,
    # and Cloudflare selects the format from the Accept header.
    it 'puts a format=auto srcset on the image, dropping widths larger than the asset' do
      transformed_html = responsivize_images(tagged_img, widths: [ 100, 200, 300 ], sizes: '100vw')
      expect(transformed_html).to eq(
        %(<img src="#{image_url}?fm=auto&amp;w=200" data-asset-id="asset-1" data-original-url="#{image_url}" loading="lazy" width="200" height="100" ) +
        %(sizes="100vw" srcset="#{image_url}?fm=auto&amp;w=100 100w, #{image_url}?fm=auto&amp;w=200 200w">)
      )
    end

    # ⚠️ Cloudflare renders and bills one transformation for each different URL. A src with
    # parameters that only look the same is a second render of each image that no browser uses.
    it 'uses the largest candidate as the src, word for word' do
      transformed_html = responsivize_images(tagged_img, widths: [ 100, 200, 300 ], sizes: '100vw')
      src = transformed_html[/\ssrc="([^"]+)"/, 1]
      candidates = transformed_html[/srcset="([^"]+)"/, 1].split(', ').map { |c| c.split(' ').first }

      expect(candidates).to include(src)
      expect(src).to eq(candidates.last)
    end

    # ⚠️ A width of 0 is present, and it would leave `0w` as the only candidate. It is the rule
    # of card_widths, which this method uses.
    it 'keeps each width, and writes no size, for an asset with a width of 0' do
      allow(self).to receive(:get_asset_dimensions).with('asset-1').and_return([ 0, 0 ])

      transformed_html = responsivize_images(tagged_img, widths: [ 100, 300 ], sizes: '100vw')

      expect(transformed_html).to include(%(srcset="#{image_url}?fm=auto&amp;w=100 100w, #{image_url}?fm=auto&amp;w=300 300w"))
      expect(transformed_html).not_to include('width="0"')
    end

    it 'inserts the asset width as a srcset candidate when it falls below the largest requested width' do
      allow(self).to receive(:get_asset_dimensions).with('asset-1').and_return([ 150, 75 ])
      transformed_html = responsivize_images(tagged_img, widths: [ 100, 300 ], sizes: '100vw')
      expect(transformed_html).to include(%(srcset="#{image_url}?fm=auto&amp;w=100 100w, #{image_url}?fm=auto&amp;w=150 150w"))
    end

    it 'crops square candidates and sets the height to the width when square' do
      transformed_html = responsivize_images(tagged_img, widths: [ 100 ], sizes: '100vw', square: true, lazy: false)
      expect(transformed_html).to eq(
        %(<img src="#{image_url}?fm=auto&amp;w=100&amp;h=100&amp;fit=cover" data-asset-id="asset-1" data-original-url="#{image_url}" width="200" height="200" ) +
        %(sizes="100vw" srcset="#{image_url}?fm=auto&amp;w=100&amp;h=100&amp;fit=cover 100w">)
      )
    end

    it 'sets dimensions and lazy loading on gifs but gives them no srcset' do
      allow(self).to receive(:get_asset_content_type).with('asset-1').and_return('image/gif')
      transformed_html = responsivize_images(tagged_img, widths: [ 100, 200 ], sizes: '100vw')
      expect(transformed_html).to eq(%(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}" loading="lazy" width="200" height="100">))
    end

    it 'skips images without a data-asset-id' do
      html = %(<img src="#{image_url}">)
      expect(responsivize_images(html)).to eq(html)
    end

    describe 'the LCP mark' do
      let(:two_images) { tagged_img * 2 }

      it 'adds no fetchpriority when the caller does not ask for it' do
        expect(responsivize_images(tagged_img, widths: [ 100 ], sizes: '100vw')).not_to include('fetchpriority')
      end

      it 'marks the first image of the page only' do
        html = responsivize_images(two_images, widths: [ 100 ], sizes: '100vw', first_image: :priority)
        expect(html.scan('fetchpriority="high"').size).to eq(1)
        expect(html.index('fetchpriority')).to be < html.index('><img')
      end

      # ⚠️ _body.html.erb calls render_body two times, for the intro and for the body. The mark
      # must cross that boundary, or each half would mark its own first image.
      it 'keeps the mark across two calls, thus the intro wins over the body' do
        first = responsivize_images(tagged_img, widths: [ 100 ], sizes: '100vw', first_image: :priority)
        second = responsivize_images(tagged_img, widths: [ 100 ], sizes: '100vw', first_image: :priority)

        expect(first).to include('fetchpriority="high"')
        expect(second).not_to include('fetchpriority')
      end

      # ⚠️ Most body images are below the fold, thus :priority must NOT make an image eager. The LCP
      # element of an article is text.
      it 'leaves the image lazy for :priority' do
        html = responsivize_images(tagged_img, widths: [ 100 ], sizes: '100vw', first_image: :priority)
        expect(html).to include('loading="lazy"')
        expect(html).not_to include('loading="eager"')
      end

      # The home page hero is the LCP element of that page. Refer to render_home_body.
      it 'makes the first image eager for :eager, and leaves the others lazy' do
        html = responsivize_images(two_images, widths: [ 100 ], sizes: '100vw', first_image: :eager)
        expect(html.scan('loading="eager"').size).to eq(1)
        expect(html.scan('loading="lazy"').size).to eq(1)
        expect(html.scan('fetchpriority="high"').size).to eq(1)
        expect(html.index('loading="eager"')).to be < html.index('loading="lazy"')
      end
    end
  end

  describe '#resize_images' do
    let(:image_url) { 'https://images.ctfassets.net/space/asset-1/token/photo.jpg' }
    let(:tagged_img) { %(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}">) }

    before do
      allow(self).to receive(:cdn_image_url) do |url, params = {}|
        params.nil? || params.empty? ? url : "#{url}?#{URI.encode_www_form(params)}"
      end
      allow(self).to receive(:get_asset_content_type).with('asset-1').and_return('image/jpeg')
    end

    it 'resizes to the asset width when it is smaller than the requested width' do
      allow(self).to receive(:get_asset_dimensions).with('asset-1').and_return([ 200, 100 ])
      transformed_html = resize_images(tagged_img, width: 1000)
      expect(transformed_html).to eq(%(<img src="#{image_url}?w=200" data-asset-id="asset-1" data-original-url="#{image_url}">))
    end

    it 'resizes to the requested width when the asset is larger' do
      allow(self).to receive(:get_asset_dimensions).with('asset-1').and_return([ 2000, 1000 ])
      transformed_html = resize_images(tagged_img, width: 1000)
      expect(transformed_html).to eq(%(<img src="#{image_url}?w=1000" data-asset-id="asset-1" data-original-url="#{image_url}">))
    end

    it 'does not resize gifs, pointing them at the CDN without params' do
      allow(self).to receive(:get_asset_dimensions).with('asset-1').and_return([ 200, 100 ])
      allow(self).to receive(:get_asset_content_type).with('asset-1').and_return('image/gif')
      transformed_html = resize_images(tagged_img, width: 1000)
      expect(transformed_html).to eq(tagged_img)
    end
  end

  describe '#add_image_placeholders' do
    let(:image_url) { 'https://images.ctfassets.net/space/asset-1/token/photo.jpg' }
    let(:tagged_img) { %(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}">) }

    it 'sets the blurhash placeholder as a CSS custom property and wires up the image-placeholder controller' do
      allow(self).to receive(:blurhash_svg_data_uri).with('asset-1').and_return('data:image/svg+xml;charset=utf-8,%3Csvg%2F%3E')
      transformed_html = add_image_placeholders(tagged_img)
      expect(transformed_html).to eq(%(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}" style="--placeholder:url('data:image/svg+xml;charset=utf-8,%3Csvg%2F%3E');" class="placeholder" data-controller="image-placeholder" data-image-placeholder-placeholder-class="placeholder" data-action="load-&gt;image-placeholder#removePlaceholder error-&gt;image-placeholder#removePlaceholder">))
    end

    it 'still adds the placeholder class and controller when no blurhash is available, but omits the style' do
      allow(self).to receive(:blurhash_svg_data_uri).with('asset-1').and_return(nil)
      transformed_html = add_image_placeholders(tagged_img)
      expect(transformed_html).not_to include('style=')
      expect(transformed_html).to include('class="placeholder"')
      expect(transformed_html).to include('data-controller="image-placeholder"')
    end

    it 'appends the placeholder class to an existing class attribute' do
      allow(self).to receive(:blurhash_svg_data_uri).with('asset-1').and_return(nil)
      html = %(<img src="#{image_url}" class="hero" data-asset-id="asset-1" data-original-url="#{image_url}">)
      expect(add_image_placeholders(html)).to include('class="hero placeholder"')
    end
  end

  describe '#set_alt_text' do
    let(:image_url) { 'https://images.ctfassets.net/space/asset-1/token/photo.jpg' }
    let(:tagged_img) { %(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}">) }

    it "sets the image's alt attribute to the asset description" do
      allow(self).to receive(:get_asset_description).with('asset-1').and_return('A finish line')
      transformed_html = set_alt_text(tagged_img)
      expect(transformed_html).to eq(%(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}" alt="A finish line">))
    end

    it 'leaves the image untouched when the asset has no description' do
      allow(self).to receive(:get_asset_description).with('asset-1').and_return(nil)
      expect(set_alt_text(tagged_img)).to eq(tagged_img)
    end
  end
end
