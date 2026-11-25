require 'spec_helper'
require 'ostruct'
require 'padrino-helpers'

RSpec.describe MarkupHelpers do
  include Padrino::Helpers
  include SiteHelpers
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

    # A `ugc` or a `nofollow` from the author must stay, as it does on each other external link.
    it 'adds to the rel that the author wrote' do
      html = "<a href=\"#{affiliate_link}\" rel=\"ugc nofollow\">Affiliate</a>"

      expect(mark_affiliate_links(html)).to eq(
        "<a href=\"#{affiliate_link}\" rel=\"sponsored nofollow noopener ugc\" target=\"_blank\">Affiliate</a>"
      )
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

  describe '#track_article_links' do
    let(:classes) { 'plausible-event-name=Article+Click plausible-event-section=Article+Body' }

    def link_class(href, extra = '')
      html = track_article_links("<a href=\"#{href}\"#{extra}>Link</a>", 'Article Body')
      Nokogiri::HTML::DocumentFragment.parse(html).at_css('a')['class']
    end

    it 'tags a relative link and a same-host link to an article' do
      expect(link_class('/2024/05/01/a-race/')).to eq(classes)
      expect(link_class('https://www.example.com/2024/05/01/a-race')).to eq(classes)
      expect(link_class('/2024/05/01/a-race/#results')).to eq(classes)
    end

    it 'keeps the classes that the author wrote' do
      expect(link_class('/2024/05/01/a-race/', ' class="note"')).to eq("note #{classes}")
    end

    it 'ignores a link to another site, to a page, to a tag, or to an anchor' do
      expect(link_class('https://www.example.org/2024/05/01/a-race/')).to be_nil
      expect(link_class('/about/')).to be_nil
      expect(link_class('/tags/running/')).to be_nil
      expect(link_class('#results')).to be_nil
      expect(link_class('mailto:me@example.com')).to be_nil
    end

    it 'ignores a link that it cannot parse' do
      expect { link_class('http://[') }.not_to raise_error
    end
  end

  describe '#render_tag_description' do
    it 'renders Markdown and applies the external-link, unit, and affiliate transforms' do
      allow(self).to receive(:amazon_associates_link?).with(external_link).and_return(false)
      text = "Run [10 km](#{external_link}) in the [shoes](#{affiliate_link}) I use, over <span data-imperial=\"6.21 mi\">10 km</span>."
      html = render_tag_description(text)

      expect(html).to include('<p>')
      # An external link that is not an affiliate link opens in a new tab.
      expect(html).to include("<a href=\"#{external_link}\" rel=\"noopener\" target=\"_blank\">10 km</a>")
      # An affiliate link gets the sponsored mark. Its step runs last, thus it replaces the value
      # from the external-link step.
      expect(html).to include('rel="sponsored nofollow noopener"')
      expect(html).to include("href=\"#{affiliate_link}\"")
      # The unit span is connected to the units controller.
      expect(html).to include('data-controller="units"')
      expect(html).to include('data-units-imperial-value="6.21 mi"')
    end
  end

  describe '#units_tag' do
    it 'takes a title in place of the default one' do
      result = units_tag('10', '6.2', title: '10 km | 6.2 mi')
      expect(result).to include('title="10 km | 6.2 mi"')
      expect(result).not_to include('title="10 | 6.2"')
    end
  end

  describe '#render_body' do
    before { MemoizationHelpers.collection_store.clear }

    let(:articles) { [] }
    let(:assets) { [] }

    def data
      OpenStruct.new(articles: articles, assets: assets,
                     srcsets: { entry: OpenStruct.new(widths: [ 100 ], sizes: [ '100vw' ]) })
    end

    # ⚠️ A listing page renders the same intro many times, and each feed renders the same body.
    it 'renders a body with no first image one time, and gives the same HTML again' do
      allow(self).to receive(:render_body_now).and_call_original

      first = render_body('Hello *there*.')
      second = render_body('Hello *there*.')

      expect(second).to eq(first)
      expect(self).to have_received(:render_body_now).once
    end

    it 'renders a body with a first image each time, because the LCP mark is for one page' do
      allow(self).to receive(:render_body_now).and_call_original

      2.times { render_body('Hello.', first_image: :eager) }

      expect(self).to have_received(:render_body_now).twice
    end

    it 'records the icons of a body that it gives again, for the sprite of this page' do
      allow(self).to receive(:record_icons_in)

      render_body('Hello.')
      render_body('Hello.')

      expect(self).to have_received(:record_icons_in).once
    end

    it 'tags the article links with a link section only, and keeps the two results apart' do
      text = 'Read [this](/2024/05/01/a-race/).'
      allow(self).to receive(:amazon_associates_link?).and_return(false)

      tagged = render_body(text, link_section: 'Article Body')
      plain = render_body(text)

      expect(tagged).to include('plausible-event-section=Article+Body')
      expect(plain).not_to include('plausible-event')
    end
  end

  describe '#render_feed_body' do
    before { MemoizationHelpers.collection_store.clear }

    let(:articles) { [] }
    let(:assets) { [] }

    def data
      OpenStruct.new(articles: articles, assets: assets, srcsets: OpenStruct.new(entry: OpenStruct.new(widths: [ 100, 200 ])))
    end

    # A feed reader cannot use a permalink, a lazy iframe, or the responsive markup. It needs the
    # figures and the affiliate marks, which say what a link is.
    it 'renders the figures and the affiliate marks, and none of the page-only transforms' do
      html = render_feed_body("## Hello\n\nRead [this](#{affiliate_link}).\n\n<iframe src=\"https://player.example/embed/1\"></iframe>")

      expect(html).to include('<h2 id="hello">Hello</h2>')
      expect(html).not_to include('entry__permalink')
      expect(html).to include('rel="sponsored nofollow noopener"')
      expect(html).to include('<figure><iframe src="https://player.example/embed/1"></iframe></figure>')
      expect(html).not_to include('loading="lazy"')
    end

    it 'renders one text one time, and gives the same HTML again' do
      allow(self).to receive(:render_feed_body_now).and_call_original

      first = render_feed_body('Hello *there*.')
      second = render_feed_body('Hello *there*.')

      expect(second).to eq(first)
      expect(self).to have_received(:render_feed_body_now).once
    end
  end

  describe '#restore_list_semantics' do
    # ⚠️ Safari removes the list semantics from VoiceOver for a list with `list-style: none`, and
    # the body lists have that. The explicit role is what keeps a numbered list a list.
    it 'gives each list an explicit list role' do
      html = '<ul><li>a</li></ul><p>x</p><ol><li>b</li></ol>'

      expect(restore_list_semantics(html)).to eq('<ul role="list"><li>a</li></ul><p>x</p><ol role="list"><li>b</li></ol>')
    end
  end

  describe '#render_markup' do
    # ⚠️ data-original-url names the Contentful host, which the image mirror keeps off the page.
    it 'removes the scratch attributes of the image transforms from the output' do
      html = render_markup('![a](https://images.ctfassets.net/space/asset-1/token/photo.jpg)') do |doc|
        add_image_data_attributes(doc)
        expect(doc.at_css('img')['data-asset-id']).to eq('asset-1')
      end
      expect(html).not_to include('data-asset-id')
      expect(html).not_to include('data-original-url')
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

    # The accessible name from the content goes into the anchor and uses its aria-label. Thus
    # without a name on the heading, a screen reader says
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

  describe '#prepend_title' do
    it 'puts the title, with a full stop, at the start of the first paragraph' do
      expect(prepend_title('Race day', '<p>It was hot.</p>')).to eq('<p><b>Race day.</b> It was hot.</p>')
    end

    it 'adds no full stop after punctuation and can hide the run-in from assistive technology' do
      expect(prepend_title('Really?', '<p>Yes.</p>', hidden_from_at: true)).to eq('<p><b aria-hidden="true">Really?</b> Yes.</p>')
    end

    it 'puts the full stop inside a closing quotation mark' do
      expect(prepend_title('&ldquo;Learn something&rdquo;', '<p>Body.</p>')).to eq('<p><b>“Learn something.”</b> Body.</p>')
    end

    it 'adds no full stop when punctuation is inside the closing quotation mark' do
      expect(prepend_title('&ldquo;Why?&rdquo;', '<p>Body.</p>')).to eq('<p><b>“Why?”</b> Body.</p>')
    end

    it 'adds a full stop after a letter outside ASCII' do
      expect(prepend_title('Café', '<p>Body.</p>')).to eq('<p><b>Café.</b> Body.</p>')
    end

    it 'makes a paragraph when the body does not start with one' do
      expect(prepend_title('Race day', '<ul><li>A</li></ul>')).to eq('<p><b>Race day.</b></p><ul><li>A</li></ul>')
    end

    it 'makes a paragraph when the body is empty' do
      expect(prepend_title('Race day', '')).to eq('<p><b>Race day.</b></p>')
    end

    # The title comes from smartypants, thus it holds entities and no escape.
    it 'keeps the entities of smartypants and escapes the markup characters of the title' do
      expect(prepend_title('It&rsquo;s "big" <b>x</b> &amp; y', '<p>Body.</p>'))
        .to eq('<p><b>It’s "big" &lt;b&gt;x&lt;/b&gt; &amp; y.</b> Body.</p>')
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
