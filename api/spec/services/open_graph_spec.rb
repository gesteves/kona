require "rails_helper"

RSpec.describe OpenGraph do
  subject(:service) { described_class.new }

  let(:url) { "https://example.test/a-post/" }
  let(:cache_key) { "open_graph:#{Digest::SHA256.hexdigest(url)}" }

  # ⚠️ #fetch caches in Redis by URL. Without this, the first example fills the key and each one
  # after it reads that answer in place of its own page.
  before { $redis.del(cache_key) }
  after  { $redis.del(cache_key) }

  def stub_page(body, success: true, code: 200)
    allow(HTTParty).to receive(:get)
      .and_return(instance_double(HTTParty::Response, success?: success, code: code, body: body))
  end

  describe "#http_url?" do
    it "accepts http and https" do
      expect(service.http_url?("https://example.test/x")).to be(true)
      expect(service.http_url?("http://example.test/x")).to be(true)
    end

    it "refuses anything else" do
      [ "", nil, "not a link", "ftp://example.test", "javascript:alert(1)", "/relative" ].each do |value|
        expect(service.http_url?(value)).to be(false)
      end
    end
  end

  describe "#fetch" do
    it "reads the og: tags" do
      stub_page(<<~HTML)
        <html><head>
          <meta property="og:title" content="Ironman Canada">
          <meta property="og:description" content="A long day.">
          <meta property="og:image" content="https://cdn.test/og.png">
        </head></html>
      HTML

      card = service.fetch(url)

      expect(card.title).to eq("Ironman Canada")
      expect(card.description).to eq("A long day.")
      expect(card.image_url).to eq("https://cdn.test/og.png")
      expect(card.url).to eq(url)
    end

    it "makes a relative og:image absolute" do
      stub_page('<html><head><meta property="og:image" content="/img/og.png"></head></html>')

      expect(service.fetch(url).image_url).to eq("https://example.test/img/og.png")
    end

    # Some pages use `name` where the tag should use `property`.
    it "falls back to the title element and the description meta" do
      stub_page(<<~HTML)
        <html><head>
          <title>A plain title</title>
          <meta name="description" content="A plain summary.">
          <meta name="twitter:image" content="https://cdn.test/tw.png">
        </head></html>
      HTML

      card = service.fetch(url)

      expect(card.title).to eq("A plain title")
      expect(card.description).to eq("A plain summary.")
      expect(card.image_url).to eq("https://cdn.test/tw.png")
    end

    # ⚠️ A Short has no cover image, and a page on another site can have no tags at all. Bluesky
    # renders a card with the URL alone, thus this must never raise and never be nil.
    it "gives the URL alone for a page with no tags" do
      stub_page("<html><head></head><body>Hi</body></html>")

      card = service.fetch(url)

      expect(card.url).to eq(url)
      expect(card.title).to be_nil
      expect(card.image_url).to be_nil
    end

    it "gives the URL alone when the host is away" do
      allow(HTTParty).to receive(:get).and_raise(SocketError, "no host")

      expect(service.fetch(url).url).to eq(url)
    end

    it "gives the URL alone for a page that is not there" do
      stub_page("Not found", success: false, code: 404)

      expect(service.fetch(url).title).to be_nil
    end

    it "makes no request for a value that is not a URL" do
      allow(HTTParty).to receive(:get)

      card = service.fetch("not a link")

      expect(card.url).to eq("not a link")
      expect(HTTParty).not_to have_received(:get)
    end
  end
end
