require 'spec_helper'

RSpec.describe MarkdownHelpers do
  describe '#heading_text' do
    it 'applies the typography and removes or escapes the markup of a title' do
      expect(heading_text(%q(It's a <b>big</b> "race" & more))).to eq('It’s a big “race” &amp; more')
      expect(heading_text('<script>x</script>')).to eq('')
      expect(heading_text('')).to be_nil
    end
  end

  describe '#html_to_markdown' do
    it 'changes HTML into Markdown and gives the text of an element with no Markdown form' do
      html = '<h2 id="x">Hi</h2><p>A <em>b</em> <a href="https://example.com">c</a> <abbr>d</abbr>.</p><ul><li>e</li></ul>'

      expect(html_to_markdown(html)).to eq("## Hi\n\nA _b_ [c](https://example.com) d.\n\n- e")
      expect(html_to_markdown('')).to be_nil
    end
  end

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
