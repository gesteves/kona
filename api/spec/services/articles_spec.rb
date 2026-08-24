require "rails_helper"

RSpec.describe Articles do
  subject(:service) { described_class.new }

  let(:item) do
    {
      "title" => "A Race Report",
      "slug" => "a-race-report",
      "summary" => "A summary.",
      "published" => "2024-05-01T10:00:00Z",
      "body" => "The body of the article.",
      "coverImage" => nil,
      "contentfulMetadata" => { "concepts" => [ { "id" => "kona" }, { "id" => "race-reports" } ] },
      "sys" => { "id" => "a1", "firstPublishedAt" => "2024-05-01T10:00:00Z", "publishedVersion" => 3 }
    }
  end

  before do
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
    allow_any_instance_of(ContentfulClient).to receive(:paginate).and_return([ item ])
  end

  describe "#list" do
    # ⚠️ RelatedArticles reads this list. The flat form keeps the cached JSON small.
    it "makes the nested taxonomy metadata into a flat concept_ids list" do
      expect(service.list.first.concept_ids).to eq(%w[kona race-reports])
    end

    it "gives an empty list of concepts for an entry with no taxonomy" do
      item.delete("contentfulMetadata")

      expect(service.list.first.concept_ids).to eq([])
    end

    it "removes the nested metadata and the body from the cached item" do
      article = service.list.first

      expect(article.to_h).not_to have_key(:contentful_metadata)
      expect(article.to_h).not_to have_key(:body)
    end

    it "keeps the derived fields of ArticleAttributes" do
      article = service.list.first

      expect(article.path).to eq("/2024/05/01/a-race-report/")
      expect(article.entry_type).to eq("Article")
      expect(article.draft).to be(false)
    end
  end
end
