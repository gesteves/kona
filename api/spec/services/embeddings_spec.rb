require "rails_helper"

RSpec.describe Embeddings do
  subject(:embeddings) { described_class.new }

  let(:vector) { [0.1, 0.2, 0.3] }
  let(:success_body) { { data: [{ embedding: vector }], usage: { total_tokens: 5 } }.to_json }

  around do |example|
    original = ENV["VOYAGE_API_KEY"]
    ENV["VOYAGE_API_KEY"] = "test-voyage-key"
    example.run
    ENV["VOYAGE_API_KEY"] = original
  end

  before do
    allow(HTTParty).to receive(:post)
      .and_return(instance_double(HTTParty::Response, success?: true, body: success_body))
  end

  it "returns the embedding vector for a document" do
    expect(embeddings.embed("Some article text")).to eq(vector)
  end

  it "posts the text to Voyage as a document with the voyage-4 model" do
    embeddings.embed("Some article text")

    expect(HTTParty).to have_received(:post).with(
      described_class::VOYAGE_API_URL,
      hash_including(
        headers: hash_including("Authorization" => "Bearer test-voyage-key"),
        body: a_string_including('"model":"voyage-4-large"', '"input_type":"document"', '"input":"Some article text"')
      )
    )
  end

  it "returns nil (and never calls the API) when the text is blank" do
    expect(embeddings.embed("")).to be_nil
    expect(HTTParty).not_to have_received(:post)
  end

  it "returns nil (and never calls the API) when the API key is unset" do
    ENV["VOYAGE_API_KEY"] = nil
    expect(described_class.new.embed("Some text")).to be_nil
    expect(HTTParty).not_to have_received(:post)
  end

  it "returns nil when the API responds with an error" do
    allow(HTTParty).to receive(:post)
      .and_return(instance_double(HTTParty::Response, success?: false, code: 429, body: "", request: nil))
    expect(embeddings.embed("Some text")).to be_nil
  end
end
