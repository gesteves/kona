require 'spec_helper'
require 'padrino-helpers'

RSpec.describe MarkupHelpers do
  include Padrino::Helpers
  include Padrino::Helpers::TagHelpers

  let(:affiliate_link) { 'https://www.amazon.com/abc123?tag=example-20' }
  let(:non_affiliate_link) { 'https://www.amazon.com/abc123' }
  let(:external_link) { 'https://www.example.com/whatever' }
  let(:internal_link) { 'https://www.giventotri.com/whatever' }

  before do
    allow(self).to receive(:is_amazon_associates_link?).with(affiliate_link).and_return(true)
    allow(self).to receive(:is_amazon_associates_link?).with(non_affiliate_link).and_return(false)
    allow(self).to receive(:root_url).and_return('https://www.giventotri.com')
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

    it 'wraps tables in responsive div containers' do
      transformed_html = responsivize_tables(html_with_table)
      expect(transformed_html).to include('<div class="entry__table"><table>')
      expect(transformed_html).to include('</table></div>')
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

      it 'handles consecutive emojis' do
        html = '<figcaption>Fantastic view 🌟✨🎯</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq('<figcaption>Fantastic view <span class="emoji">🌟</span><span class="emoji">✨</span><span class="emoji">🎯</span></figcaption>')
      end

      it 'works with different emoji categories including variation selectors' do
        html = '<figcaption>Perfect day 😎☀️🌈</figcaption>'
        transformed_html = wrap_figcaption_emoji(html)
        expect(transformed_html).to eq('<figcaption>Perfect day <span class="emoji">😎</span><span class="emoji">☀️</span><span class="emoji">🌈</span></figcaption>')
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
      it 'returns the html unchanged' do
        expect(wrap_figcaption_emoji('')).to eq('')
        expect(wrap_figcaption_emoji(nil)).to be_nil
      end
    end
  end
end
