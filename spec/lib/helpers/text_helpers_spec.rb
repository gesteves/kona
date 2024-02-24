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
      expect(comma_join_with_and(['apple', 'banana', 'cherry'])).to eq("apple, banana and cherry")
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

  describe '#sanitize' do
    let(:markdown) { '**bold** and _italic_ with a <span>span</span> for good measure' }

    it 'returns plain text, stripping HTML tags and Markdown syntax' do
      text = sanitize(markdown)
      expect(text).to eq('bold and italic with a span for good measure')
    end
  end
end
