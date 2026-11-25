require "rails_helper"

RSpec.describe ArticleIndex do
  # Makes the document shape that Articles#corpus gives.
  def doc(title: nil, summary: nil, intro: nil, body: nil)
    { title: title, summary: summary, intro: intro, body: body }
  end

  describe "#similarity" do
    subject(:index) { described_class.new(documents) }

    let(:documents) do
      {
        "q" => doc(body: "alpha bravo charlie delta"),
        "near" => doc(body: "alpha bravo charlie zulu"),
        "far" => doc(body: "alpha yankee xray whiskey"),
        "none" => doc(body: "quebec romeo sierra tango")
      }
    end

    it "gives a larger value to the document that shares more words" do
      expect(index.similarity("q", "near")).to be > index.similarity("q", "far")
    end

    it "gives zero for two documents that share no word" do
      expect(index.similarity("q", "none")).to eq(0.0)
    end

    it "is never negative" do
      pairs = documents.keys.combination(2)

      expect(pairs.map { |a, b| index.similarity(a, b) }).to all(be >= 0.0)
    end

    it "does not change when the order of the two ids changes" do
      expect(index.similarity("q", "near")).to eq(index.similarity("near", "q"))
    end

    it "gives 1.0 for a document against itself" do
      expect(index.similarity("q", "q")).to be_within(1e-9).of(1.0)
    end

    it "gives zero for an id that the index does not hold" do
      expect(index.similarity("q", "missing")).to eq(0.0)
    end
  end

  # ⚠️ This is what replaces the mean subtraction that an embedding needed. A word that most of the
  # corpus holds carries almost no information, and the IDF must remove it.
  it "gives almost no weight to a word that each document shares" do
    common = described_class.new(
      "a" => doc(body: "triathlon triathlon triathlon alpha"),
      "b" => doc(body: "triathlon triathlon triathlon bravo"),
      "c" => doc(body: "triathlon triathlon triathlon charlie"),
      "d" => doc(body: "triathlon triathlon triathlon delta")
    )

    expect(common.similarity("a", "b")).to be < 0.05
  end

  # ⚠️ The length normalization is what keeps a Short in the running. The median Article is
  # approximately eighteen times longer than the median Short.
  it "does not let a long document win only because it is long" do
    index = described_class.new(
      "query" => doc(body: "kona ironman"),
      "short" => doc(body: "kona ironman"),
      "long" => doc(body: "kona ironman #{Array.new(400) { |i| "filler#{i}" }.join(' ')}")
    )

    expect(index.similarity("query", "short")).to be > index.similarity("query", "long")
  end

  it "counts a word in the title more than the same word in the body" do
    index = described_class.new(
      "query" => doc(title: "boise"),
      "titled" => doc(title: "boise", body: "alpha bravo charlie delta echo"),
      "body" => doc(title: "zulu", body: "boise alpha bravo charlie delta echo")
    )

    expect(index.similarity("query", "titled")).to be > index.similarity("query", "body")
  end

  it "reads Markdown as its words and not as its syntax" do
    index = described_class.new(
      "plain" => doc(body: "kona ironman canada"),
      "markdown" => doc(body: "**kona** [ironman](https://example.com/) _canada_")
    )

    expect(index.similarity("plain", "markdown")).to be_within(1e-9).of(1.0)
  end

  describe "#terms_in_common" do
    subject(:index) do
      described_class.new(
        "a" => doc(body: "kona ironman canada alpha"),
        "b" => doc(body: "kona ironman canada bravo"),
        "c" => doc(body: "charlie delta echo foxtrot")
      )
    end

    it "names the words that the two documents share" do
      expect(index.terms_in_common("a", "b")).to contain_exactly("kona", "ironman", "canada")
    end

    it "gives no more than the limit" do
      expect(index.terms_in_common("a", "b", limit: 2).size).to eq(2)
    end

    it "gives an empty list for two documents that share no word" do
      expect(index.terms_in_common("a", "c")).to eq([])
    end
  end

  describe "#key?" do
    it "is true for a document that has words" do
      expect(described_class.new("a" => doc(body: "kona")).key?("a")).to be(true)
    end

    it "is false for a document with no text" do
      expect(described_class.new("a" => doc).key?("a")).to be(false)
    end

    it "is false for an id that the index does not hold" do
      expect(described_class.new("a" => doc(body: "kona")).key?("b")).to be(false)
    end
  end

  it "does not raise for an empty corpus" do
    expect { described_class.new({}) }.not_to raise_error
  end
end
