require "rails_helper"

RSpec.describe MarkdownLinks do
  # @param source [String]
  # @return [Array] The plain text, and each link as [words, address].
  def parsed(source)
    result = described_class.parse(source)
    [ result.text, result.links.map { |link| [ result.text[link.start...link.finish], link.url ] } ]
  end

  describe ".parse" do
    it "reads an inline link" do
      expect(parsed("Read [my post](https://example.test/a) today"))
        .to eq([ "Read my post today", [ [ "my post", "https://example.test/a" ] ] ])
    end

    it "reads a reference link and takes its definition line out of the post" do
      expect(parsed("Read [my post][a] today\n\n[a]: https://example.test/a"))
        .to eq([ "Read my post today", [ [ "my post", "https://example.test/a" ] ] ])
    end

    # ⚠️ `[words][]` and `[words]` both name the words. One branch covers the two.
    it "reads a collapsed and a short reference the same way" do
      expect(parsed("See [kona][] soon\n\n[kona]: https://example.test/k").first).to eq("See kona soon")
      expect(parsed("See [kona] soon\n\n[kona]: https://example.test/k").first).to eq("See kona soon")
    end

    it "folds the case of a definition name, as CommonMark does" do
      expect(parsed("Read [my post][A] today\n\n[a]: https://example.test/a").last)
        .to eq([ [ "my post", "https://example.test/a" ] ])
    end

    # ⚠️ Each of these keeps its brackets. A post is 300 characters of a person writing a sentence,
    # thus this grammar must never take words away that the owner meant to keep.
    describe "the words that are NOT a link" do
      {
        "an address that is not http"   => "I ate [a lot](really) today",
        "a name with no definition"     => "Bad ref [words][nope] stays",
        "brackets with nothing near"    => "That was [wild] today",
        "a definition of no address"    => "See [a] soon\n\n[a]: notalink",
        "a link with no words"          => "[](https://example.test/a) here"
      }.each do |name, source|
        it "keeps #{name} exactly as it is" do
          expect(parsed(source)).to eq([ source, [] ])
        end
      end
    end

    # ⚠️ This is the failure of a renderer that makes HTML and then searches the plain text for each
    # label: it would put both facets on the FIRST "one".
    it "gives two links with the same words their own offsets" do
      result = described_class.parse("[one](https://a.test) and [one](https://b.test)")

      expect(result.text).to eq("one and one")
      expect(result.links.map(&:start)).to eq([ 0, 8 ])
      expect(result.links.map(&:url)).to eq([ "https://a.test", "https://b.test" ])
    end

    # ⚠️ The offsets are CHARACTERS, and Bluesky#link_facet makes the bytes. One accented letter is
    # 1 character and 2 bytes, thus a byte offset here would move each highlight after it.
    it "counts the offsets in characters and not in bytes" do
      link = described_class.parse("café [ünïcode](https://example.test/a)").links.first

      expect([ link.start, link.finish ]).to eq([ 5, 12 ])
    end

    it "takes each definition line out, whatever its place in the draft" do
      expect(parsed("[a]: https://example.test/a\nRead [my post][a] today").first)
        .to eq("Read my post today")
    end

    # ⚠️ Without the trim a post would carry the empty lines of its own syntax.
    it "leaves no blank line where a definition was" do
      expect(parsed("A long day.\n\n[a]: https://example.test/a\n").first).to eq("A long day.")
    end

    it "reads a definition line that a CRLF ends" do
      expect(parsed("Read [my post][a]\r\n\r\n[a]: https://example.test/a\r\n").first)
        .to eq("Read my post")
    end

    it "reads a definition of at most three spaces of indent" do
      expect(parsed("See [a] soon\n\n   [a]: https://example.test/a").first).to eq("See a soon")
      expect(parsed("See [a] soon\n\n    [a]: https://example.test/a").first)
        .to eq("See [a] soon\n\n    [a]: https://example.test/a")
    end
  end

  describe ".render" do
    it "gives the plain text alone" do
      expect(described_class.render("Read [my post](https://example.test/a)")).to eq("Read my post")
    end

    it "takes nil" do
      expect(described_class.render(nil)).to eq("")
    end
  end

  # ⚠️ This is the ONE test of "the owner wrote Markdown". The composer turns two checkboxes off by
  # it, and the action refuses a draft by it, thus a sentence with brackets in it must answer false.
  describe ".links?" do
    it "is true for a draft with a link" do
      expect(described_class.links?("Read [my post](https://example.test/a)")).to be(true)
      expect(described_class.links?("Read [my post][a]\n\n[a]: https://example.test/a")).to be(true)
    end

    it "is false for a draft with brackets and no link" do
      expect(described_class.links?("That was [wild] today")).to be(false)
      expect(described_class.links?("I ate [a lot](really)")).to be(false)
      expect(described_class.links?("Plain words")).to be(false)
      expect(described_class.links?(nil)).to be(false)
    end

    # ⚠️ A bare URL is not Markdown. Each of the three networks makes a link of one, thus a draft
    # that holds one must still be able to go to all of them.
    it "is false for a bare URL" do
      expect(described_class.links?("Read https://example.test/a today")).to be(false)
    end
  end
end
