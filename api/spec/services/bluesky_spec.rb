require "rails_helper"

RSpec.describe Bluesky do
  let(:credentials) { BlueskyCredentials::Credentials.new(handle: "me.bsky.social", app_password: "pw") }
  subject(:service) { described_class.new(credentials: credentials) }

  let(:session_body) do
    { accessJwt: "jwt", did: "did:plc:abc",
      didDoc: { service: [ { id: "#atproto_pds", serviceEndpoint: "https://pds.test" } ] } }.to_json
  end

  def stub_session
    allow(HTTParty).to receive(:post)
      .with(a_string_including("com.atproto.server.createSession"), anything)
      .and_return(instance_double(HTTParty::Response, success?: true, body: session_body))
  end

  # Captures the record that putRecord sent, so an example can read it.
  def stub_put_record
    allow(HTTParty).to receive(:post)
      .with(a_string_including("com.atproto.repo.putRecord"), anything) do |_url, options|
        @sent = JSON.parse(options[:body])
        instance_double(HTTParty::Response, success?: true, body: "{}", code: 200)
      end
  end

  describe ".post_length" do
    # ⚠️ Bluesky counts graphemes. `String#length` gives UTF-16 code units, thus it counts one
    # emoji as 2 or more. share_controller.js counts the same way with Intl.Segmenter.
    it "counts one emoji as one character" do
      expect(described_class.post_length("👍")).to eq(1)
      expect(described_class.post_length("👨‍👩‍👧‍👦")).to eq(1)
    end

    it "counts a combining accent with its letter" do
      expect(described_class.post_length("é")).to eq(1)
    end
  end

  describe ".valid_post_length?" do
    it "refuses an empty post and one past the limit" do
      expect(described_class.valid_post_length?("")).to be(false)
      expect(described_class.valid_post_length?("a" * 301)).to be(false)
    end

    it "accepts a post at the limit" do
      expect(described_class.valid_post_length?("a" * 300)).to be(true)
    end

    # The admin page and this service must refuse the same drafts.
    it "uses the same limit as the admin page" do
      expect(described_class::MAX_GRAPHEMES).to eq(SharePresenter::BODY_LIMIT)
    end
  end

  describe ".new_tid" do
    it "makes a 13-character key of the sortable alphabet" do
      expect(described_class.new_tid).to match(/\A[234567a-z]{13}\z/)
    end

    # ⚠️ A later post must sort after an earlier one, thus the key comes from the clock.
    it "grows over time" do
      first = described_class.new_tid
      sleep 0.002
      expect(described_class.new_tid).to be > first
    end
  end

  describe "#post!" do
    before do
      stub_session
      stub_put_record
    end

    it "refuses when there are no credentials" do
      service = described_class.new(credentials: BlueskyCredentials::Credentials.new(handle: nil, app_password: nil))

      expect { service.post!(rkey: "abc", text: "Hi") }.to raise_error(/not connected/)
    end

    it "refuses a post past the limit before it opens a session" do
      expect { service.post!(rkey: "abc", text: "a" * 301) }.to raise_error(/longer than 300/)
      expect(HTTParty).not_to have_received(:post)
    end

    it "writes the post and answers with its public URL" do
      url = service.post!(rkey: "3kabc", text: "A long day.")

      expect(url).to eq("https://bsky.app/profile/me.bsky.social/post/3kabc")
      expect(@sent["collection"]).to eq("app.bsky.feed.post")
      expect(@sent["rkey"]).to eq("3kabc")
      expect(@sent["record"]["text"]).to eq("A long day.")
      expect(@sent["record"]["langs"]).to eq([ "en-US" ])
    end

    # ⚠️ The PDS knows the app.bsky.* lexicons, thus it must check the record. standard.site sends
    # validate:false, because a PDS does not know its lexicons.
    it "lets the PDS validate the record" do
      service.post!(rkey: "3kabc", text: "Hi")

      expect(@sent).not_to have_key("validate")
    end

    describe "the website card" do
      let(:card) do
        OpenGraph::Card.new(url: "https://example.test/post/", title: "A title",
                            description: "A summary.", image_url: "https://cdn.test/og.png")
      end

      before do
        allow(HTTParty).to receive(:get)
          .with("https://cdn.test/og.png", anything)
          .and_return(instance_double(HTTParty::Response, success?: true, body: "bytes", code: 200,
                                      headers: { "content-type" => "image/png" }))
        allow(HTTParty).to receive(:post)
          .with(a_string_including("com.atproto.repo.uploadBlob"), anything)
          .and_return(instance_double(HTTParty::Response, success?: true, code: 200,
                                      body: { blob: { "$type" => "blob" } }.to_json))
      end

      it "makes an app.bsky.embed.external with the thumbnail" do
        service.post!(rkey: "3kabc", text: "Read this", card: card)

        embed = @sent["record"]["embed"]
        expect(embed["$type"]).to eq("app.bsky.embed.external")
        expect(embed["external"]["uri"]).to eq("https://example.test/post/")
        expect(embed["external"]["title"]).to eq("A title")
        expect(embed["external"]["description"]).to eq("A summary.")
        expect(embed["external"]["thumb"]).to eq({ "$type" => "blob" })
      end

      # ⚠️ The link is the card, and it is not in the text. Thus the URL uses none of the 300
      # characters.
      it "keeps the URL out of the text" do
        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(@sent["record"]["text"]).to eq("Read this")
      end

      # A card with no picture still renders. Thus a failed image must never lose the post.
      it "still posts when the image fails" do
        allow(HTTParty).to receive(:get)
          .with("https://cdn.test/og.png", anything)
          .and_return(instance_double(HTTParty::Response, success?: false, code: 500, body: "",
                                      headers: {}))

        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(@sent["record"]["embed"]["external"]).not_to have_key("thumb")
      end

      # ⚠️ The card of a Short, or of a page on another site, has no og:image at all. The post must
      # still go out.
      it "posts a card with no picture" do
        bare = OpenGraph::Card.new(url: "https://example.test/short/", title: "A short",
                                   description: nil, image_url: nil)

        service.post!(rkey: "3kabc", text: "Read this", card: bare)

        expect(@sent["record"]["embed"]["external"]).not_to have_key("thumb")
        expect(@sent["record"]["embed"]["external"]["uri"]).to eq("https://example.test/short/")
      end

      # ⚠️ A blob past the limit fails at putRecord and not at the upload, thus the whole post
      # would go away and the message would name the embed.
      it "shrinks a picture that is over the blob limit" do
        big = "x" * (described_class::MAX_BLOB_BYTES + 1)
        allow(HTTParty).to receive(:get)
          .with("https://cdn.test/og.png", anything)
          .and_return(instance_double(HTTParty::Response, success?: true, body: big, code: 200,
                                      headers: { "content-type" => "image/png" }))
        # A true image, thus the resize and the JPEG encode really run. The download is the only
        # stub: `big` stands for a file that is too large, and libvips never decodes it.
        allow(Vips::Image).to receive(:new_from_buffer).and_return(Vips::Image.black(2400, 1200))

        uploaded = nil
        allow(HTTParty).to receive(:post)
          .with(a_string_including("com.atproto.repo.uploadBlob"), anything) do |_url, options|
            uploaded = options
            instance_double(HTTParty::Response, success?: true, code: 200,
                            body: { blob: { "$type" => "blob" } }.to_json)
          end

        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(uploaded[:body].bytesize).to be < described_class::MAX_BLOB_BYTES
        expect(uploaded[:headers]["Content-Type"]).to eq("image/jpeg")
        expect(@sent["record"]["embed"]["external"]["thumb"]).to eq({ "$type" => "blob" })
      end
    end

    describe "the facets" do
      it "marks a bare URL" do
        service.post!(rkey: "3kabc", text: "See https://example.test/x for more")

        facet = @sent["record"]["facets"].first
        expect(facet["features"].first["$type"]).to eq("app.bsky.richtext.facet#link")
        expect(facet["features"].first["uri"]).to eq("https://example.test/x")
        expect(facet["index"]).to eq({ "byteStart" => 4, "byteEnd" => 26 })
      end

      it "marks a hashtag without its #" do
        service.post!(rkey: "3kabc", text: "Done #ironman")

        facet = @sent["record"]["facets"].first
        expect(facet["features"].first).to eq({ "$type" => "app.bsky.richtext.facet#tag", "tag" => "ironman" })
      end

      it "resolves a mention to a DID" do
        allow(HTTParty).to receive(:get)
          .with(a_string_including("resolveHandle"), anything)
          .and_return(instance_double(HTTParty::Response, success?: true,
                                      body: { did: "did:plc:xyz" }.to_json))

        service.post!(rkey: "3kabc", text: "Hi @friend.bsky.social")

        facet = @sent["record"]["facets"].first
        expect(facet["features"].first).to eq({ "$type" => "app.bsky.richtext.facet#mention", "did" => "did:plc:xyz" })
      end

      # ⚠️ A mention facet with no DID makes the record invalid, thus the code drops it.
      it "drops a mention that the PDS cannot resolve" do
        allow(HTTParty).to receive(:get)
          .with(a_string_including("resolveHandle"), anything)
          .and_return(instance_double(HTTParty::Response, success?: false, code: 400, body: ""))

        service.post!(rkey: "3kabc", text: "Hi @nobody.bsky.social")

        expect(@sent["record"]["facets"]).to be_nil
      end

      # ⚠️ The offsets are in bytes of the UTF-8 text, and not in characters. An accented letter is
      # 1 character and 2 bytes, thus a character offset would move each highlight after it.
      it "counts the offsets in bytes" do
        service.post!(rkey: "3kabc", text: "café https://example.test/x")

        expect(@sent["record"]["facets"].first["index"]["byteStart"]).to eq(6)
      end

      it "sends no facets for plain words" do
        service.post!(rkey: "3kabc", text: "Just some words")

        expect(@sent["record"]).not_to have_key("facets")
      end
    end

    it "raises when the PDS refuses the write, thus the job runs again" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.putRecord"), anything)
        .and_return(instance_double(HTTParty::Response, success?: false, code: 400, body: "bad"))

      expect { service.post!(rkey: "3kabc", text: "Hi") }.to raise_error(/refused/)
    end
  end
end
