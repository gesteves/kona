require "rails_helper"

RSpec.describe RelatedArticles do
  subject(:service) { described_class.new(articles: articles, plausible: plausible, taxonomy: taxonomy) }

  let(:articles) { instance_double(Articles) }
  let(:plausible) { instance_double(Plausible, totals_by_path: nil) }
  let(:taxonomy) { instance_double(TaxonomyConcepts, tree: tree) }
  let(:tree) { {} }

  # Makes an article with the fields that Articles#list gives.
  def article(id:, slug:, published_at:, entry_type: "Article", draft: false, concept_ids: [])
    path = "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
    DeepOstruct.wrap(
      title: slug.capitalize, slug: slug, summary: "A summary.", published_at: published_at,
      entry_type: entry_type, draft: draft, path: path, concept_ids: concept_ids,
      sys: { id: id, published_version: 1 }
    )
  end

  # The words go in the body alone, thus one word is one token and the field weights do not apply.
  # A word that two documents share raises their similarity, and a word of its own lowers it.
  def texts(map)
    map.transform_values { |words| { title: nil, summary: nil, intro: nil, body: words } }
  end

  # `near` shares three words with the query, `mid` shares two, and `far` shares one. Each
  # candidate shares no word with another candidate, thus MMR cannot change this order. The draft
  # and the Short repeat the query exactly, thus their similarity is the largest of all. That shows
  # that the code removes them for their id and their type, and not for a low score.
  let(:corpus) do
    texts(
      "q1" => "alpha bravo charlie delta echo foxtrot",
      "near" => "alpha bravo charlie near1 near2 near3",
      "mid" => "delta echo mid1 mid2 mid3 mid4",
      "far" => "foxtrot far1 far2 far3 far4 far5",
      "draft" => "alpha bravo charlie delta echo foxtrot",
      "short" => "alpha bravo charlie delta echo foxtrot"
    )
  end

  let(:list) do
    [
      article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z"),
      article(id: "near", slug: "near", published_at: "2024-04-01T10:00:00Z"),
      article(id: "mid", slug: "mid", published_at: "2024-03-01T10:00:00Z"),
      article(id: "far", slug: "far", published_at: "2024-02-01T10:00:00Z"),
      article(id: "draft", slug: "draft", published_at: "2024-01-01T10:00:00Z", draft: true),
      article(id: "short", slug: "short", published_at: "2024-01-15T10:00:00Z", entry_type: "Short")
    ]
  end

  before do
    allow(articles).to receive(:list).and_return(list)
    allow(articles).to receive(:corpus).and_return(corpus)
  end

  describe "#all" do
    it "puts the neighbors of each entry in order, the nearest first" do
      expect(service.all["q1"]).to eq(%w[near mid far])
    end

    it "omits the query article itself, a draft, and a Short" do
      expect(service.all["q1"]).not_to include("q1", "draft", "short")
    end

    # ⚠️ A Short is a correct query article, because the section appears on its own page.
    # ArticleRanking#candidates keeps it out of each neighbor list.
    it "keys a Short, and never gives one as a neighbor" do
      result = service.all

      expect(result).to have_key("short")
      expect(result.values.flatten).not_to include("short")
    end

    it "omits a draft as a query article and as a neighbor" do
      result = service.all

      expect(result).not_to have_key("draft")
      expect(result.values.flatten).not_to include("draft")
    end

    it "omits an entry with no text" do
      allow(articles).to receive(:corpus).and_return(corpus.except("near"))
      result = service.all

      expect(result).not_to have_key("near")
      expect(result.values.flatten).not_to include("near")
    end

    it "gives no more than `count` neighbors" do
      expect(service.all(count: 1)["q1"]).to eq(%w[near])
    end

    # ⚠️ The index is made one time for the full corpus, and not one time for each query article.
    it "makes the index one time" do
      expect(articles).to receive(:corpus).once.and_return(corpus)

      service.all
    end

    it "gives every candidate it has when the corpus is smaller than count" do
      expect(service.all(count: 10)["q1"]).to eq(%w[near mid far])
    end

    it "gives an empty hash and does not raise when the corpus is not available" do
      allow(articles).to receive(:list).and_return([])

      expect(service.all).to eq({})
    end
  end

  # ⚠️ The prior is what selects inside a group of candidates with a near-equal relevance. The
  # candidates have the same text, thus the prior alone decides the order.
  describe "the prior" do
    let(:corpus) do
      texts(
        "q1" => "alpha bravo charlie",
        "a" => "alpha bravo charlie",
        "b" => "alpha bravo charlie"
      )
    end

    let(:list) do
      [
        article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z"),
        article(id: "a", slug: "a", published_at: "2023-05-01T10:00:00Z"),
        article(id: "b", slug: "b", published_at: "2023-05-01T10:00:00Z")
      ]
    end

    it "puts the more popular candidate first" do
      allow(plausible).to receive(:totals_by_path).and_return(
        "/2023/05/01/a/" => { visitors: 5, pageviews: 5 },
        "/2023/05/01/b/" => { visitors: 500, pageviews: 600 }
      )

      expect(service.all["q1"]).to eq(%w[b a])
    end

    # A reader of a race report goes to the other reports of that season.
    it "puts the candidate from the same season first" do
      allow(articles).to receive(:list).and_return([
        article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z"),
        article(id: "a", slug: "a", published_at: "2023-05-01T10:00:00Z"),
        article(id: "b", slug: "b", published_at: "2024-04-15T10:00:00Z")
      ])

      expect(service.all["q1"]).to eq(%w[b a])
    end

    it "gives the prior in the report" do
      allow(plausible).to receive(:totals_by_path).and_return("/2023/05/01/b/" => { visitors: 500, pageviews: 600 })
      rows = service.explain("q1")[:rows].index_by { |row| row[:id] }

      expect(rows["b"][:prior]).to be > rows["a"][:prior]
    end
  end

  # ⚠️ A link that the author wrote is a strong sign that two entries are related, and the index
  # cannot see it: the plain text of the corpus holds no URL.
  describe "the links" do
    let(:corpus) do
      texts(
        "q1" => "alpha bravo charlie [see](/2024/04/01/linked/)",
        "linked" => "alpha bravo charlie",
        "plain" => "alpha bravo charlie"
      )
    end

    let(:list) do
      [
        article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z"),
        article(id: "linked", slug: "linked", published_at: "2024-04-01T10:00:00Z"),
        article(id: "plain", slug: "plain", published_at: "2024-04-01T10:00:00Z")
      ]
    end

    it "puts the entry that the query article links to first" do
      expect(service.all["q1"]).to eq(%w[linked plain])
    end

    # The two candidates have one link each, thus their text is the same length. The link of
    # `plain` goes to no entry.
    it "counts a link in the other direction" do
      allow(articles).to receive(:corpus).and_return(
        texts(
          "q1" => "alpha bravo charlie",
          "linked" => "alpha bravo charlie [back](/2024/05/01/self/)",
          "plain" => "alpha bravo charlie [away](/2019/01/01/nowhere/)"
        )
      )

      expect(service.all["q1"].first).to eq("linked")
    end

    it "marks the link in the report" do
      rows = service.explain("q1")[:rows].index_by { |row| row[:id] }

      expect(rows["linked"][:link]).to be(true)
      expect(rows["plain"][:link]).to be(false)
    end
  end

  describe "the taxonomy" do
    let(:tree) do
      {
        "triathlon" => { broader: [], scheme: "sports" },
        "full-distance" => { broader: [ "triathlon" ], scheme: "sports" },
        "kona" => { broader: [ "full-distance" ], scheme: "sports" },
        "race-reports" => { broader: [], scheme: "topics" }
      }
    end

    let(:corpus) do
      texts(
        "q1" => "alpha bravo charlie",
        "shared" => "alpha bravo charlie",
        "alone" => "alpha bravo charlie"
      )
    end

    let(:list) do
      [
        article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z",
                concept_ids: %w[kona race-reports]),
        article(id: "shared", slug: "shared", published_at: "2024-04-01T10:00:00Z",
                concept_ids: %w[kona race-reports]),
        article(id: "alone", slug: "alone", published_at: "2024-04-01T10:00:00Z",
                concept_ids: %w[race-reports])
      ]
    end

    # The two candidates have the same text. Thus the concept overlap alone decides the order.
    it "puts the article that shares a rare concept above one that shares only a common concept" do
      expect(service.all["q1"].first).to eq("shared")
    end

    it "does not raise when the concept tree is not available" do
      allow(taxonomy).to receive(:tree).and_raise(StandardError, "down")

      expect { service.all }.not_to raise_error
    end
  end

  describe "#explain" do
    it "gives each part of the score of each candidate" do
      report = service.explain("q1")
      row = report[:rows].first

      expect(row).to include(:id, :title, :lexical, :overlap, :link, :relevance, :prior, :score, :selected)
      expect(row[:id]).to eq("near")
      expect(row[:selected]).to be(true)
    end

    # ⚠️ A person cannot read a vector, and a person can read these words. This column is the
    # reason to prefer a lexical index to an embedding.
    it "names the words that the two articles share" do
      row = service.explain("q1")[:rows].find { |r| r[:id] == "near" }

      expect(row[:terms]).to contain_exactly("alpha", "bravo", "charlie")
    end

    it "gives nil for an entry that the index does not hold" do
      expect(service.explain("unknown")).to be_nil
    end
  end

  # ⚠️ MMR is what makes the section go wider. The nearest four articles are frequently
  # near-copies of each other, thus the reader got one direction and not four.
  describe "the MMR diversity" do
    # Each candidate shares the same three words with the query. But c1, c2, and c3 also share
    # three words with each other, and `other` shares none. Thus the four are equally relevant and
    # only the diversity separates them.
    let(:corpus) do
      texts(
        "q1" => "alpha bravo charlie",
        "c1" => "alpha bravo charlie kilo lima mike c1x",
        "c2" => "alpha bravo charlie kilo lima mike c2x",
        "c3" => "alpha bravo charlie kilo lima mike c3x",
        "other" => "alpha bravo charlie oscar papa quebec romeo"
      )
    end

    let(:list) do
      %w[q1 c1 c2 c3 other].each_with_index.map do |id, index|
        article(id: id, slug: id, published_at: "2024-0#{5 - index}-01T10:00:00Z")
      end
    end

    it "selects a different article before a third near-copy" do
      expect(service.all(count: 2)["q1"]).to eq(%w[c1 other])
    end

    it "still puts the nearest article first" do
      expect(service.all(count: 4)["q1"].first).to eq("c1")
    end

    # This is the order with no diversity, and it is what MMR corrects above.
    it "gives three near-copies when the balance is relevance only" do
      stub_const("RelatedArticles::MMR_LAMBDA", 1.0)

      expect(service.all(count: 3)["q1"]).to eq(%w[c1 c2 c3])
    end
  end

  describe "the same-race demotion" do
    let(:tree) do
      {
        "triathlon" => { broader: [], scheme: "sports" },
        "full-distance" => { broader: [ "triathlon" ], scheme: "sports" },
        "kona" => { broader: [ "full-distance" ], scheme: "sports" },
        "roth" => { broader: [ "full-distance" ], scheme: "sports" }
      }
    end

    let(:corpus) do
      texts(
        "q1" => "alpha bravo charlie",
        "same" => "alpha bravo charlie",
        "different" => "alpha bravo charlie"
      )
    end

    let(:list) do
      [
        article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z", concept_ids: %w[kona]),
        article(id: "same", slug: "same", published_at: "2024-04-01T10:00:00Z", concept_ids: %w[kona]),
        article(id: "different", slug: "different", published_at: "2024-04-01T10:00:00Z", concept_ids: %w[roth])
      ]
    end

    # The concept overlap is off, thus this example measures the demotion alone. The two
    # candidates have the same text.
    it "lowers the score of a report of the same race" do
      stub_const("RelatedArticles::LEXICAL_WEIGHT", 1.0)
      rows = service.explain("q1")[:rows].index_by { |row| row[:id] }

      expect(rows["same"][:relevance]).to be < rows["different"][:relevance]
    end

    # ⚠️ It is a demotion and never an exclusion. A Short renders the related section with no
    # "More Reports From This Race" section above it, thus the same race must stay available. The
    # demotion is also small on purpose: a shared rare concept is true relatedness, and it wins.
    it "keeps a report of the same race in the list" do
      expect(service.all["q1"]).to include("same")
    end
  end
end
