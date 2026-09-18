require "rails_helper"

RSpec.describe SocialText do
  describe ".url_ranges" do
    # ⚠️ The range is trimmed, thus the punctuation of the sentence stays outside the address and
    # keeps its typography.
    it "finds each bare address, without the punctuation after it" do
      text = "See https://example.test/x. Then http://other.test/y, and done"

      ranges = described_class.url_ranges(text)

      expect(ranges.map { |range| text[range] }).to eq([ "https://example.test/x", "http://other.test/y" ])
    end

    it "gives no range for a text with no address, or with no text" do
      expect(described_class.url_ranges("plain words")).to eq([])
      expect(described_class.url_ranges(nil)).to eq([])
    end
  end

  describe ".compose" do
    it "puts the link below the words, and omits an empty part" do
      expect(described_class.compose(text: " Hello ", url: "https://example.test/")).to eq("Hello\n\nhttps://example.test/")
      expect(described_class.compose(text: "Hello", url: nil)).to eq("Hello")
      expect(described_class.compose(text: "", url: "https://example.test/")).to eq("https://example.test/")
    end
  end

  describe ".graphemes" do
    it "counts as a person reads: one emoji with a skin tone is one" do
      text = "👍🏽 ok"

      expect(described_class.graphemes(text)).to eq(4)
      expect(text.length).to be > 4
    end

    it "counts nothing for nil" do
      expect(described_class.graphemes(nil)).to eq(0)
    end
  end
end
