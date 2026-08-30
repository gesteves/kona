require "rails_helper"

RSpec.describe Typography do
  describe ".apply" do
    it "curls a quotation mark and an apostrophe" do
      expect(described_class.apply(%q(It's a "big" day))).to eq("It’s a “big” day")
    end

    it "writes an ellipsis and the two dashes" do
      expect(described_class.apply("Wait... A -- B and C --- D")).to eq("Wait… A – B and C — D")
    end

    # ⚠️ SmartyPants is a renderer of HTML: it writes `&rsquo;` and not `’`. A post holds
    # characters, thus a missing decode would put the entity itself in the feed.
    it "writes characters and never an HTML entity" do
      expect(described_class.apply(%q(It's))).not_to include("&")
    end

    it "leaves plain words alone" do
      expect(described_class.apply("plain words")).to eq("plain words")
      expect(described_class.apply("")).to eq("")
      expect(described_class.apply(nil)).to eq("")
    end

    # ⚠️ **This is the reason that this class exists**, and the reason that the helper is not called
    # directly. Each of these gives a link that is dead, and nothing reports it.
    describe "an address" do
      {
        "a dash pair"  => "See https://example.test/a--b now",
        "three dots"   => "See https://example.test/a...b now",
        "an apostrophe" => "See https://example.test/it's now"
      }.each do |name, draft|
        it "goes through with no change, for #{name}" do
          expect(described_class.apply(draft)).to eq(draft)
        end
      end

      it "is left alone while the words around it are not" do
        expect(described_class.apply(%q(It's here: https://example.test/a--b... really)))
          .to eq("It’s here: https://example.test/a--b… really")
      end

      # ⚠️ The mask is what makes this work. With a split at each address, SmartyPants reads two
      # pieces, opens the quotation in the first and never closes it.
      it "does not stop a quotation from closing" do
        expect(described_class.apply(%q(He said "see https://example.test/x now" loudly)))
          .to eq("He said “see https://example.test/x now” loudly")
      end

      it "keeps more than one address in its own place" do
        draft = "a https://example.test/a--b b https://example.test/c...d e"

        expect(described_class.apply(draft)).to eq(draft)
      end
    end

    # ⚠️ The Markdown parse runs after this, thus its syntax must come through untouched.
    describe "the Markdown syntax" do
      it "leaves an inline link alone and curls the words around it" do
        expect(described_class.apply(%q{Read [my post](https://example.test/a--b) -- it's good}))
          .to eq("Read [my post](https://example.test/a--b) – it’s good")
      end

      it "leaves a definition line alone" do
        expect(described_class.apply("Ref [a][x]... good\n\n[x]: https://example.test/a--b"))
          .to eq("Ref [a][x]… good\n\n[x]: https://example.test/a--b")
      end
    end

    # ⚠️ The mask stands for an address, thus a draft that already holds one would put the addresses
    # back in the wrong places. That character is not text and it renders as nothing.
    it "removes a mask that the draft already holds" do
      expect(described_class.apply("a#{described_class::PLACEHOLDER}b")).to eq("ab")
    end
  end

  # ⚠️ It is the SAME typography as the blog, through MarkdownHelper#smartypants. The owner writes
  # for one voice, thus a post and the article that it links to must not use a different
  # apostrophe.
  it "gives the same answer as the helper of the site, for text with no address" do
    helper = Class.new { include MarkdownHelper }.new

    expect(described_class.apply(%q(It's a "big" day...)))
      .to eq(HTMLEntities.new.decode(helper.smartypants(%q(It's a "big" day...))))
  end
end
