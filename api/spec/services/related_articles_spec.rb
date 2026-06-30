require "rails_helper"

RSpec.describe RelatedArticles do
  subject(:service) { described_class.new(articles: articles) }

  let(:articles) { instance_double(Articles) }

  # Builds a decorated article the way Articles#list would return it.
  def article(id:, slug:, published_at:, entry_type: "Article", draft: false)
    path = "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
    DeepOstruct.wrap(
      title: slug.capitalize, slug: slug, summary: "A summary.", published_at: published_at,
      entry_type: entry_type, draft: draft, path: path, sys: { id: id }
    )
  end

  def vec_json(vector)
    { version: 1, vector: vector }.to_json
  end

  # Vectors chosen so cosine(query, ·) orders near > mid > far; self/draft/short share the query's
  # vector (cosine 1) to prove they're excluded by identity/type, not by a low score.
  let(:store) do
    {
      "embeddings:article:q1" => vec_json([1.0, 0.0, 0.0]),
      "embeddings:article:near" => vec_json([0.9, 0.1, 0.0]),
      "embeddings:article:mid" => vec_json([0.5, 0.5, 0.0]),
      "embeddings:article:far" => vec_json([0.0, 1.0, 0.0]),
      "embeddings:article:draft" => vec_json([1.0, 0.0, 0.0]),
      "embeddings:article:short" => vec_json([1.0, 0.0, 0.0])
    }
  end

  let(:corpus) do
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
    allow(articles).to receive(:list).and_return(corpus)
    # The ranked result is cached via cached_json; stub Redis so the suite stays Redis-free. The
    # ranked-cache key isn't in `store`, so get returns nil (a miss) and the ranking is computed.
    allow($redis).to receive(:get) { |key| store[key] }
    allow($redis).to receive(:setex)
    allow($redis).to receive(:mget) { |*keys| keys.map { |key| store[key] } }
  end

  it "ranks candidates by cosine similarity to the query article, nearest first" do
    expect(service.for_article("q1").map(&:slug)).to eq(%w[near mid far])
  end

  it "excludes the query article itself, drafts, and Shorts" do
    slugs = service.for_article("q1").map(&:slug)
    expect(slugs).not_to include("self", "draft", "short")
  end

  it "returns an empty list when the query article has no stored vector" do
    expect(service.for_article("unknown")).to eq([])
  end

  it "honors the count limit" do
    expect(service.for_article("q1", count: 2).map(&:slug)).to eq(%w[near mid])
  end

  it "skips candidates that have no stored vector yet" do
    store.delete("embeddings:article:mid")
    expect(service.for_article("q1").map(&:slug)).to eq(%w[near far])
  end

  context "when two candidates are equally similar" do
    let(:store) do
      {
        "embeddings:article:q1" => vec_json([1.0, 0.0, 0.0]),
        "embeddings:article:older" => vec_json([0.5, 0.5, 0.0]),
        "embeddings:article:newer" => vec_json([0.5, 0.5, 0.0])
      }
    end

    let(:corpus) do
      [
        article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z"),
        article(id: "older", slug: "older", published_at: "2024-01-01T10:00:00Z"),
        article(id: "newer", slug: "newer", published_at: "2024-04-01T10:00:00Z")
      ]
    end

    it "breaks the tie toward the more recently published article" do
      expect(service.for_article("q1").map(&:slug)).to eq(%w[newer older])
    end
  end
end
