require 'spec_helper'

RSpec.describe TextHelpers do
  describe "#remove_widows" do
    it "replaces the space between the last two words with a non-breaking space" do
      expect(remove_widows("Test sentence here")).to eq("Test sentence&nbsp;here")
      expect(remove_widows("Test sentence")).to eq("Test&nbsp;sentence")
      expect(remove_widows("Test")).to eq("Test")
    end

    it "returns nil for blank text" do
      expect(remove_widows("")).to be_nil
    end
  end

  describe "#comma_join_with_and" do
    it "joins an array with commas and 'and'" do
      expect(comma_join_with_and(['apple', 'banana', 'cherry'], false)).to eq("apple, banana and cherry")
      expect(comma_join_with_and(['apple', 'banana', 'cherry'], true)).to eq("apple, banana, and cherry")
    end
  end

  describe "#with_indefinite_article" do
    it "prefixes word with 'a' or 'an' appropriately" do
      expect(with_indefinite_article("apple")).to eq("an apple")
      expect(with_indefinite_article("banana")).to eq("a banana")
      expect(with_indefinite_article("60-minute workout")).to eq("a 60-minute workout")
      expect(with_indefinite_article("80-minute workout")).to eq("an 80-minute workout")
    end
  end

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
