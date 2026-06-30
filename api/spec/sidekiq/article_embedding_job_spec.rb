require "rails_helper"

RSpec.describe ArticleEmbeddingJob do
  let(:articles) { instance_double(Articles) }
  let(:embeddings) { instance_double(Embeddings) }
  let(:article) do
    DeepOstruct.wrap(
      title: "A Title", intro: "An intro.", body: "A body.", sys: { id: "entry123", published_version: 7 }
    )
  end

  before do
    allow(Articles).to receive(:new).and_return(articles)
    allow(Embeddings).to receive(:new).and_return(embeddings)
    allow($redis).to receive(:set)
    allow($redis).to receive(:del)
  end

  describe "embed" do
    before do
      allow(articles).to receive(:find_for_embedding).with("entry123").and_return(article)
      allow(embeddings).to receive(:embed).and_return([0.1, 0.2])
    end

    it "embeds title + intro + body and stores the vector keyed by entry id" do
      described_class.new.perform("embed", "entry123")

      expect(embeddings).to have_received(:embed).with("A Title\n\nAn intro.\n\nA body.")
      expect($redis).to have_received(:set).with(
        "embeddings:article:entry123",
        { version: 7, vector: [0.1, 0.2] }.to_json
      )
    end

    it "stores nothing when the embedding call fails" do
      allow(embeddings).to receive(:embed).and_return(nil)
      described_class.new.perform("embed", "entry123")
      expect($redis).not_to have_received(:set)
    end

    it "stores nothing when the article can't be fetched" do
      allow(articles).to receive(:find_for_embedding).with("entry123").and_return(nil)
      described_class.new.perform("embed", "entry123")
      expect($redis).not_to have_received(:set)
    end
  end

  describe "delete" do
    it "removes the stored vector" do
      described_class.new.perform("delete", "entry123")
      expect($redis).to have_received(:del).with("embeddings:article:entry123")
    end
  end

  it "ignores a blank entry id" do
    described_class.new.perform("embed", "")
    expect($redis).not_to have_received(:set)
  end

  it "logs and ignores an unknown operation" do
    expect(Rails.logger).to receive(:warn).with(/unknown operation/)
    described_class.new.perform("frobnicate", "entry123")
  end

  it "is configured to retry" do
    expect(described_class.get_sidekiq_options["retry"]).to eq(5)
  end
end
