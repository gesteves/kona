require "rails_helper"

RSpec.describe ContentfulClient do
  subject(:client) { described_class.new("SomeConsumer") }

  let(:gql) { "query($skip: Int, $limit: Int) { articleCollection { items { sys { id } } } }" }

  around do |example|
    original = ENV.slice("CONTENTFUL_SPACE", "CONTENTFUL_TOKEN")
    ENV["CONTENTFUL_SPACE"] = "space123"
    ENV["CONTENTFUL_TOKEN"] = "token123"
    example.run
    ENV["CONTENTFUL_SPACE"] = original["CONTENTFUL_SPACE"]
    ENV["CONTENTFUL_TOKEN"] = original["CONTENTFUL_TOKEN"]
  end

  # One item hash for each id, with the shape of the collection payload that paginate reads.
  def page_of(count, start: 0)
    Array.new(count) { |i| { sys: { id: "entry-#{start + i}" } } }
  end

  # The code reads `[:data]` of the result of post_json. A nil response means a page that failed.
  def stub_pages(*pages)
    responses = pages.map do |page|
      page && { data: { articleCollection: { items: page } } }
    end
    allow(client).to receive(:post_json).and_return(*responses)
  end

  describe "#query" do
    it "returns nil without touching the network when unconfigured" do
      ENV["CONTENTFUL_SPACE"] = ""

      expect(client).not_to receive(:post_json)
      expect(client.query(gql)).to be_nil
    end

    it "posts to the configured space and returns the data payload" do
      expect(client).to receive(:post_json).with(
        "#{described_class::CONTENTFUL_API_URL}/space123",
        hash_including(headers: hash_including("Authorization" => "Bearer token123"))
      ).and_return({ data: { articleCollection: { items: [] } } })

      expect(client.query(gql)).to eq({ articleCollection: { items: [] } })
    end

    it "omits blank variables from the request body" do
      expect(client).to receive(:post_json) do |_url, options|
        expect(JSON.parse(options[:body])).to eq({ "query" => gql })
        { data: {} }
      end

      client.query(gql)
    end

    it "includes variables when given" do
      expect(client).to receive(:post_json) do |_url, options|
        expect(JSON.parse(options[:body])["variables"]).to eq({ "skip" => 0, "limit" => 100 })
        { data: {} }
      end

      client.query(gql, { skip: 0, limit: 100 })
    end
  end

  describe "#paginate" do
    it "walks pages until a short one and concatenates them" do
      stub_pages(page_of(2), page_of(2, start: 2), page_of(1, start: 4))

      result = client.paginate(gql, collection: :articleCollection, page_size: 2)

      expect(result.map { |i| i[:sys][:id] }).to eq(%w[entry-0 entry-1 entry-2 entry-3 entry-4])
    end

    it "stops after one page when it is already short" do
      stub_pages(page_of(1))

      expect(client.paginate(gql, collection: :articleCollection, page_size: 2).size).to eq(1)
    end

    it "stops on an exactly-full page followed by an empty one" do
      stub_pages(page_of(2), [])

      expect(client.paginate(gql, collection: :articleCollection, page_size: 2).size).to eq(2)
    end

    # The two conditions of `strict:`. A list that uses an incomplete set of articles removes some
    # articles with no message. A widget with an incomplete set only shows fewer items.
    it "returns the partial result when a page fails and strict is false" do
      stub_pages(page_of(2), nil)

      expect(client.paginate(gql, collection: :articleCollection, page_size: 2).size).to eq(2)
    end

    it "returns nil when a page fails and strict is true" do
      stub_pages(page_of(2), nil)

      expect(client.paginate(gql, collection: :articleCollection, page_size: 2, strict: true)).to be_nil
    end

    it "returns nil on a first-page failure under strict" do
      stub_pages(nil)

      expect(client.paginate(gql, collection: :articleCollection, strict: true)).to be_nil
    end
  end
end
