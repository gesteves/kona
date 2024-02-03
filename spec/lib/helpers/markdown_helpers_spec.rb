require 'spec_helper'

RSpec.describe MarkdownHelpers do
  describe '#markdown_to_html' do
    context 'when text is provided' do
      let(:markdown) { '**bold** _italic_ [link](http://example.com)' }

      it 'converts markdown to HTML' do
        html = markdown_to_html(markdown)
        expect(html).to include('<strong>bold</strong>')
        expect(html).to include('<em>italic</em>')
        expect(html).to include('<a href="http://example.com">link</a>')
      end
    end

    context 'when text is blank' do
      it 'returns nil' do
        expect(markdown_to_html('')).to be_nil
      end
    end
  end

  describe '#markdown_to_text' do
    let(:markdown) { '**bold** and _italic_' }

    it 'converts markdown to plain text, stripping HTML tags' do
      text = markdown_to_text(markdown)
      expect(text).to eq('bold and italic')
    end
  end

  describe '#smartypants' do
    let(:text) { "Quotes 'single quotes' and \"double quotes\"" }

    it 'applies SmartyPants rendering to the text' do
      rendered_text = smartypants(text)
      expect(rendered_text).to include('&lsquo;single quotes&rsquo;')
      expect(rendered_text).to include('&ldquo;double quotes&rdquo;')
    end

    context 'when text is blank' do
      it 'returns nil' do
        expect(smartypants('')).to be_nil
      end
    end
  end
end
