require 'spec_helper'
require 'padrino-helpers'

RSpec.describe MarkupHelpers do
  include Padrino::Helpers
  include Padrino::Helpers::TagHelpers

  let(:affiliate_link) { 'https://www.amazon.com/abc123?tag=example-20' }
  let(:non_affiliate_link) { 'https://www.amazon.com/abc123' }
  let(:external_link) { 'https://www.example.org/whatever' }
  let(:internal_link) { 'https://www.example.com/whatever' }

  before do
    allow(self).to receive(:amazon_associates_link?).with(affiliate_link).and_return(true)
    allow(self).to receive(:amazon_associates_link?).with(non_affiliate_link).and_return(false)
    allow(self).to receive(:root_url).and_return('https://www.example.com')
  end

  describe '#add_unit_data_attributes' do
    context 'when given an element with a data-imperial data attribute' do
      let(:html) { '<span data-imperial="6.21 mi">10 km</span>' }

      it 'adds the correct data attributes' do
        transformed_html = add_unit_data_attributes(html)
        expect(transformed_html).to eq('<span data-controller="units" data-units-imperial-value="6.21 mi" data-units-metric-value="10 km" title="10 km | 6.21 mi">10 km</span>')
      end
    end

    context 'when given an element without a data-imperial data attribute' do
      let(:html) { '<span data-whatever="6.21 mi">10 km</span>' }

      it 'adds the correct data attributes' do
        transformed_html = add_unit_data_attributes(html)
        expect(transformed_html).to eq(html)
      end
    end

    context 'when html is blank' do
      it 'returns nil' do
        expect(add_unit_data_attributes('')).to be_nil
      end
    end
  end

  describe '#responsivize_tables' do
    let(:html_with_table) { '<table><tr><td>Example</td></tr></table>' }

    it 'wraps tables in a horizontal wa-scroller' do
      transformed_html = responsivize_tables(html_with_table)
      expect(transformed_html).to include('<wa-scroller class="entry__table" orientation="horizontal"><table>')
      expect(transformed_html).to include('</table></wa-scroller>')
    end
  end

  describe '#scope_table_headers' do
    it 'marks header cells as column headers' do
      transformed_html = scope_table_headers('<table><thead><tr><th></th><th>Bike</th></tr></thead><tbody><tr><td>Sweat rate</td><td>1.48 L/h</td></tr></tbody></table>')
      expect(transformed_html).to include('<th scope="col"></th>')
      expect(transformed_html).to include('<th scope="col">Bike</th>')
      expect(transformed_html).to include('<td>Sweat rate</td>')
    end
  end

  describe '#split_table_cell_annotations' do
    it 'wraps the text after a line break in an annotation' do
      transformed_html = split_table_cell_annotations('<table><tbody><tr><td>1.48 L/h<br>62nd percentile</td></tr></tbody></table>')
      expect(transformed_html).to include('<td>1.48 L/h<small class="entry__table-annotation">62nd percentile</small>')
    end

    it 'splits only at the first line break' do
      transformed_html = split_table_cell_annotations('<table><tbody><tr><td>1.5 L<br>29% replaced<br>moderate</td></tr></tbody></table>')
      expect(transformed_html).to include('<small class="entry__table-annotation">29% replaced<br>moderate</small>')
    end

    it 'preserves markup inside the annotation' do
      transformed_html = split_table_cell_annotations('<table><tbody><tr><th>33 mmol/L<br><em>759</em> mg/L</th></tr></tbody></table>')
      expect(transformed_html).to include('<small class="entry__table-annotation"><em>759</em> mg/L</small>')
    end

    it 'leaves cells without a line break alone' do
      transformed_html = split_table_cell_annotations('<table><tbody><tr><td>882 mg/h</td></tr></tbody></table>')
      expect(transformed_html).to include('<td>882 mg/h</td>')
      expect(transformed_html).not_to include('<small')
    end
  end

  describe '#mark_affiliate_links' do
    let(:html_with_affiliate_link) { "<a href=\"#{affiliate_link}\">Affiliate</a>" }
    let(:html_without_affiliate_link) { "<a href=\"#{non_affiliate_link}\">Non-Affiliate</a>" }

    it 'marks affiliate links as sponsored and opens them in new tabs' do
      transformed_html = mark_affiliate_links(html_with_affiliate_link)
      expect(transformed_html).to eq("<a href=\"#{affiliate_link}\" rel=\"sponsored nofollow noopener\" target=\"_blank\">Affiliate</a>")
    end

    it 'does not mark non-affiliate links as sponsored or opens them in new tabs' do
      transformed_html = mark_affiliate_links(html_without_affiliate_link)
      expect(transformed_html).to eq(html_without_affiliate_link)
    end
  end

  describe '#open_external_links_in_new_tabs' do
    let(:html_with_external_link) { "<a href=\"#{external_link}\">External</a>" }
    let(:html_without_external_link) { "<a href=\"#{internal_link}\">Internal</a>" }

    it 'opens external links in new tabs' do
      transformed_html = open_external_links_in_new_tabs(html_with_external_link)
      expect(transformed_html).to eq("<a href=\"#{external_link}\" rel=\"noopener\" target=\"_blank\">External</a>")
    end

    it 'does not open internal links in new tabs' do
      transformed_html = open_external_links_in_new_tabs(html_without_external_link)
      expect(transformed_html).to eq(html_without_external_link)
    end
  end

  describe '#render_tag_description' do
    it 'renders Markdown and applies the external-link, unit, and affiliate transforms' do
      allow(self).to receive(:amazon_associates_link?).with(external_link).and_return(false)
      text = "Run [10 km](#{external_link}) in the [shoes](#{affiliate_link}) I use, over <span data-imperial=\"6.21 mi\">10 km</span>."
      html = render_tag_description(text)

      expect(html).to include('<p>')
      # External (non-affiliate) link opens in a new tab.
      expect(html).to include("<a href=\"#{external_link}\" rel=\"noopener\" target=\"_blank\">10 km</a>")
      # Affiliate link is marked sponsored — its pass runs last, so it wins over the external pass.
      expect(html).to include('rel="sponsored nofollow noopener"')
      expect(html).to include("href=\"#{affiliate_link}\"")
      # Unit span is wired to the units controller.
      expect(html).to include('data-controller="units"')
      expect(html).to include('data-units-imperial-value="6.21 mi"')
    end
  end

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

      # Splitting on an element's text content and replacing it with plain text nodes threw the
      # element away — a whole caption written as one link lost the link.
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

  describe '#prepend_title' do
    context 'when the body starts with a paragraph' do
      it 'prepends the bold title inline into the first paragraph' do
        transformed_html = prepend_title('A short title', '<p>The body text.</p>')
        expect(transformed_html).to eq('<p><b>A short title.</b> The body text.</p>')
      end

      it 'does not add a period when the title ends with punctuation' do
        transformed_html = prepend_title('A short title!', '<p>The body text.</p>')
        expect(transformed_html).to eq('<p><b>A short title!</b> The body text.</p>')
      end
    end

    context 'when the body does not start with a paragraph' do
      it 'inserts the title as its own paragraph' do
        transformed_html = prepend_title('A short title', '<figure></figure>')
        expect(transformed_html).to eq('<p><b>A short title.</b></p><figure></figure>')
      end
    end

    context 'when hidden_from_at is true' do
      it 'marks the inline title aria-hidden' do
        transformed_html = prepend_title('A short title', '<p>The body text.</p>', hidden_from_at: true)
        expect(transformed_html).to eq('<p><b aria-hidden="true">A short title.</b> The body text.</p>')
      end
    end
  end

  describe '#add_heading_permalinks' do
    before do
      allow(self).to receive(:icon_svg).and_return('<svg></svg>')
    end

    it 'adds permalink anchors to h2 and h3 headings with ids' do
      html = '<h2 id="first">First</h2><h3 id="second">Second</h3>'
      transformed_html = add_heading_permalinks(html)
      expect(transformed_html).to include('<a href="#first" class="entry__heading-permalink"')
      expect(transformed_html).to include('<a href="#second" class="entry__heading-permalink"')
    end

    it 'does not add permalink anchors to other heading levels' do
      html = '<h4 id="fourth">Fourth</h4><h5 id="fifth">Fifth</h5>'
      transformed_html = add_heading_permalinks(html)
      expect(transformed_html).not_to include('entry__heading-permalink')
    end

    it 'skips headings without an id' do
      html = '<h2>No anchor</h2>'
      transformed_html = add_heading_permalinks(html)
      expect(transformed_html).not_to include('entry__heading-permalink')
    end

    it 'labels each permalink with the heading text for assistive tech' do
      html = '<h2 id="first">First Heading</h2>'
      doc = Nokogiri::HTML::DocumentFragment.parse(add_heading_permalinks(html))
      anchor = doc.at_css('a.entry__heading-permalink')
      expect(anchor['aria-label']).to eq('Permalink to First Heading')
      expect(anchor['title']).to eq('Permalink to First Heading')
    end

    it 'escapes HTML-sensitive characters in the heading text' do
      html = '<h2 id="qa">Q&amp;A about "gear" &lt;2026&gt;</h2>'
      doc = Nokogiri::HTML::DocumentFragment.parse(add_heading_permalinks(html))
      anchor = doc.at_css('a.entry__heading-permalink')
      expect(anchor['aria-label']).to eq('Permalink to Q&A about "gear" <2026>')
      expect(anchor['title']).to eq('Permalink to Q&A about "gear" <2026>')
    end

    # Accessible name from content descends into the nested anchor and uses its aria-label, so
    # without an explicit name on the heading itself every heading announced as
    # "Permalink to First Heading First Heading".
    it 'names the heading after its own text, not the nested permalink' do
      html = '<h2 id="first">First Heading</h2>'
      doc = Nokogiri::HTML::DocumentFragment.parse(add_heading_permalinks(html))

      expect(doc.at_css('h2')['aria-label']).to eq('First Heading')
    end

    it 'leaves headings without an id unnamed' do
      doc = Nokogiri::HTML::DocumentFragment.parse(add_heading_permalinks('<h2>No anchor</h2>'))

      expect(doc.at_css('h2')['aria-label']).to be_nil
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

    # The transform folds the rest of the parent into the caption and then replaces the parent,
    # so a second image in the same paragraph used to end up inside the first one's <figcaption>
    # and detached from the tree mid-iteration.
    context 'with two images in one paragraph' do
      it 'leaves them alone rather than swallowing the second into the first figcaption' do
        html = %(<p><img src="#{image_url}"><img src="#{image_url}"></p>)
        transformed_html = add_figure_elements_to_images(html, base_class: 'entry')

        expect(transformed_html).to eq(html)
        expect(transformed_html).not_to include('figcaption')
      end
    end

    context 'when the asset has no known content type' do
      # E.g. a hotlinked non-Contentful image: no content-type modifier, just the base class.
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

  describe '#add_figure_elements_to_iframes' do
    let(:iframe_html) { '<iframe src="https://player.example/embed/1"></iframe>' }

    context 'with a base class' do
      # Note the asymmetry with add_figure_elements_to_images: the figure replaces the
      # iframe *inside* its parent — the wrapping <p> is kept, not replaced.
      it 'wraps the iframe in a figure with the base and iframe modifier classes, inside the original parent' do
        transformed_html = add_figure_elements_to_iframes("<p>#{iframe_html}</p>", base_class: 'entry')
        expect(transformed_html).to eq(%(<p><figure class="entry__figure entry__figure--iframe">#{iframe_html}</figure></p>))
      end

      it 'reuses an existing figure parent, replacing its class instead of nesting a new figure' do
        transformed_html = add_figure_elements_to_iframes("<figure>#{iframe_html}</figure>", base_class: 'entry')
        expect(transformed_html).to eq(%(<figure class="entry__figure entry__figure--iframe">#{iframe_html}</figure>))
      end
    end

    context 'without a base class' do
      it 'wraps the iframe in a classless figure' do
        transformed_html = add_figure_elements_to_iframes("<p>#{iframe_html}</p>")
        expect(transformed_html).to eq(%(<p><figure>#{iframe_html}</figure></p>))
      end
    end
  end

  describe '#add_figure_elements_to_embeds' do
    let(:embed_html) { '<blockquote class="bluesky-embed"><p>A post</p></blockquote><script src="https://embed.bsky.app/static/embed.js"></script>' }

    context 'with a base class' do
      it 'wraps the blockquote + script pair in a figure with the base and embed modifier classes' do
        transformed_html = add_figure_elements_to_embeds(embed_html, base_class: 'entry')
        # Nokogiri serializes a newline before the <script>; pinned as-is.
        expect(transformed_html).to eq(%(<figure class="entry__figure entry__figure--embed"><blockquote class="bluesky-embed"><p>A post</p></blockquote>\n<script src="https://embed.bsky.app/static/embed.js"></script></figure>))
      end

      it 'reuses an existing figure parent, replacing its class instead of nesting a new figure' do
        transformed_html = add_figure_elements_to_embeds("<figure>#{embed_html}</figure>", base_class: 'entry')
        expect(transformed_html).to eq(%(<figure class="entry__figure entry__figure--embed"><blockquote class="bluesky-embed"><p>A post</p></blockquote>\n<script src="https://embed.bsky.app/static/embed.js"></script></figure>))
      end
    end

    it 'leaves a blockquote without a following script untouched' do
      html = '<blockquote><p>A post</p></blockquote>'
      expect(add_figure_elements_to_embeds(html, base_class: 'entry')).to eq(html)
    end
  end

  describe '#responsivize_images' do
    let(:image_url) { 'https://images.ctfassets.net/space/asset-1/token/photo.jpg' }
    let(:tagged_img) { %(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}">) }

    before do
      # Deterministic stand-in for the CDN URL builder: append the params as a query string.
      allow(self).to receive(:cdn_image_url) do |url, params = {}|
        params.nil? || params.empty? ? url : "#{url}?#{URI.encode_www_form(params)}"
      end
      allow(self).to receive(:get_asset_dimensions).with('asset-1').and_return([ 200, 100 ])
      allow(self).to receive(:get_asset_content_type).with('asset-1').and_return('image/jpeg')
    end

    # No <picture> and no per-format <source>: one srcset asking for format=auto, which Cloudflare
    # negotiates from the Accept header.
    it 'puts a format=auto srcset on the image, dropping widths larger than the asset' do
      transformed_html = responsivize_images(tagged_img, widths: [ 100, 200, 300 ], sizes: '100vw')
      expect(transformed_html).to eq(
        %(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}" loading="lazy" width="200" height="100" ) +
        %(sizes="100vw" srcset="#{image_url}?fm=auto&amp;w=100 100w, #{image_url}?fm=auto&amp;w=200 200w">)
      )
    end

    it 'inserts the asset width as a srcset candidate when it falls below the largest requested width' do
      allow(self).to receive(:get_asset_dimensions).with('asset-1').and_return([ 150, 75 ])
      transformed_html = responsivize_images(tagged_img, widths: [ 100, 300 ], sizes: '100vw')
      expect(transformed_html).to include(%(srcset="#{image_url}?fm=auto&amp;w=100 100w, #{image_url}?fm=auto&amp;w=150 150w"))
    end

    it 'crops square candidates and sets the height to the width when square' do
      transformed_html = responsivize_images(tagged_img, widths: [ 100 ], sizes: '100vw', square: true, lazy: false)
      expect(transformed_html).to eq(
        %(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}" width="200" height="200" ) +
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
      expect(transformed_html).to eq(%(<img src="#{image_url}" data-asset-id="asset-1" data-original-url="#{image_url}" style="--placeholder:url('data:image/svg+xml;charset=utf-8,%3Csvg%2F%3E');" class="placeholder" data-controller="image-placeholder" data-action="load-&gt;image-placeholder#removePlaceholder error-&gt;image-placeholder#removePlaceholder">))
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

  describe '#lazy_load_iframes' do
    it 'adds loading="lazy" to iframes' do
      html = '<iframe src="https://player.example/embed/1"></iframe>'
      transformed_html = lazy_load_iframes(html)
      expect(transformed_html).to eq('<iframe src="https://player.example/embed/1" loading="lazy"></iframe>')
    end
  end

  describe '#copy_feed_links' do
    it 'wires feed links to the clipboard controller with the success message' do
      html = '<a href="https://example.com/feed.xml">Subscribe</a>'
      transformed_html = copy_feed_links(html)
      expect(transformed_html).to eq('<a href="https://example.com/feed.xml" data-controller="clipboard" data-action="click-&gt;clipboard#copy" data-clipboard-success-message-value="The link to the feed has been copied to your clipboard.">Subscribe</a>')
    end

    it 'leaves non-feed links untouched' do
      html = '<a href="https://example.com/about">About</a>'
      expect(copy_feed_links(html)).to eq(html)
    end
  end
end
