require 'spec_helper'

RSpec.describe TextHelpers do
  describe "#fix_degrees" do
    it "replaces the masculine ordinal indicator with the degree sign" do
      expect(fix_degrees("It's 72ºF outside")).to eq("It's 72°F outside")
      expect(fix_degrees("0º, 90º, and 180º")).to eq("0°, 90°, and 180°")
    end

    it "leaves text without the wrong unit untouched" do
      expect(fix_degrees("It's 72°F outside")).to eq("It's 72°F outside")
    end

    it "returns nil for blank text" do
      expect(fix_degrees("")).to be_nil
    end
  end

  describe '#sanitize' do
    let(:markdown) { '**bold** & _italic_ with a <span>span</span> for good measure' }

    it 'returns plain text, stripping HTML tags and Markdown syntax' do
      text = sanitize(markdown)
      expect(text).to eq('bold & italic with a span for good measure')
    end

    it 'returns plain text, stripping HTML tags and Markdown syntax, and escaping HTML entities' do
      text = sanitize(markdown, escape_html_entities: true)
      expect(text).to eq('bold &amp; italic with a span for good measure')
    end
  end
end
