require "rails_helper"

RSpec.describe OpenGraph do
  subject(:service) { described_class.new }

  let(:url) { "https://example.test/a-post/" }
  let(:cache_key) { "open_graph:#{Digest::SHA256.hexdigest(url)}" }

  # ⚠️ #fetch caches in Redis by URL. Without this, the first example fills the key and each one
  # after it reads that answer in place of its own page.
  before { $redis.del(cache_key) }
  after  { $redis.del(cache_key) }

  def stub_page(body, code: 200, **options)
    stub_streamed_get(body: body, code: code, headers: { "content-type" => "text/html; charset=utf-8" }, **options)
  end

  describe ".http_url?" do
    it "accepts http and https" do
      expect(described_class.http_url?("https://example.test/x")).to be(true)
      expect(described_class.http_url?("http://example.test/x")).to be(true)
    end

    it "refuses anything else" do
      [ "", nil, "not a link", "ftp://example.test", "javascript:alert(1)", "/relative" ].each do |value|
        expect(described_class.http_url?(value)).to be(false)
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

    # ⚠️ The page can redirect to another host. A relative picture belongs to the host that
    # answered, and not to the URL that the owner typed.
    it "resolves a relative og:image against the final URL after a redirect" do
      stub_page('<html><head><meta property="og:image" content="/img/og.png"></head></html>',
                final_url: "https://moved.test/posts/a-post/")

      expect(service.fetch(url).image_url).to eq("https://moved.test/img/og.png")
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

    it "reads a page with an accented title" do
      stub_page('<html><head><meta property="og:title" content="Café du Cycliste"></head></html>')

      expect(service.fetch(url).title).to eq("Café du Cycliste")
    end

    # ⚠️ The tags are in the <head>, and the worker is a 512MB VM. The read stops at MAX_BYTES and
    # the rest of a long page never arrives.
    it "reads the first MAX_BYTES of a long page and keeps the tags" do
      head = '<html><head><meta property="og:title" content="A long page"></head><body>'
      stub_page(head + ("x" * described_class::MAX_BYTES), fragments: 8)

      expect(service.fetch(url).title).to eq("A long page")
    end

    # ⚠️ These tags are what let Bluesky render the standard.site card in place of the ordinary
    # one. A crawler runs no JavaScript, thus the build of web/ writes both into the head.
    it "reads the standard.site link tags" do
      stub_page(<<~HTML)
        <html><head>
          <link rel="site.standard.publication" href="at://did:plc:abc/site.standard.publication/pub1">
          <link rel="site.standard.document" href="at://did:plc:abc/site.standard.document/doc1">
        </head></html>
      HTML

      card = service.fetch(url)

      expect(card.document_uri).to eq("at://did:plc:abc/site.standard.document/doc1")
      expect(card.publication_uri).to eq("at://did:plc:abc/site.standard.publication/pub1")
    end

    # A page on another site publishes no such tag, and Bluesky then renders the ordinary card.
    it "gives no at:// URI for a page with no standard.site tags" do
      stub_page("<html><head><title>Hi</title></head></html>")

      card = service.fetch(url)

      expect(card.document_uri).to be_nil
      expect(card.publication_uri).to be_nil
    end

    # ⚠️ A ref must be an at:// URI. A tag with another value is not one, and a record that cannot
    # be read would fail the whole post.
    it "ignores a link tag whose href is not an at:// URI" do
      stub_page(%(<html><head><link rel="site.standard.document" href="/a-post/"></head></html>))

      expect(service.fetch(url).document_uri).to be_nil
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
      stub_page("Not found", code: 404)

      expect(service.fetch(url).title).to be_nil
    end

    it "sends its own user agent, with a timeout" do
      stub_page("<html></html>")

      service.fetch(url)

      expect(HTTParty).to have_received(:get).with(
        url,
        hash_including(headers: hash_including("User-Agent" => described_class::USER_AGENT),
                       open_timeout: described_class::OPEN_TIMEOUT,
                       read_timeout: described_class::READ_TIMEOUT)
      )
    end

    it "makes no request for a value that is not a URL" do
      allow(HTTParty).to receive(:get)

      card = service.fetch("not a link")

      expect(card.url).to eq("not a link")
      expect(HTTParty).not_to have_received(:get)
    end
  end
end
