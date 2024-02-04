require 'spec_helper'

RSpec.describe MarkupHelpers do
  let(:affiliate_link) { 'https://www.amazon.com/abc123?tag=example-20' }
  let(:non_affiliate_link) { 'https://www.amazon.com/abc123' }
  let(:external_link) { 'https://www.example.com/whatever' }
  let(:internal_link) { 'https://www.giventotri.com/whatever' }

  before do
    allow(self).to receive(:is_affiliate_link?).with(affiliate_link).and_return(true)
    allow(self).to receive(:is_affiliate_link?).with(non_affiliate_link).and_return(false)
    allow(self).to receive(:root_url).and_return('https://www.giventotri.com')
  end

  describe '#add_unit_data_attributes' do
    context 'when given an element with a data-imperial data attribute' do
      let(:html) { '<span data-imperial="6.21 mi">10 km</span>' }

      it 'adds the correct data attributes' do
        transformed_html = add_unit_data_attributes(html)
        expect(transformed_html).to eq('<span data-units-imperial-value="6.21 mi" data-units-metric-value="10 km" data-controller="units">10 km</span>')
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
end
