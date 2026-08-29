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
        # putRecord answers with the reference of the record that it wrote.
        body = { uri: "at://did:plc:abc/#{@sent['collection']}/#{@sent['rkey']}", cid: "bafypost" }
        instance_double(HTTParty::Response, success?: true, body: body.to_json, code: 200)
      end
  end

  describe ".post_length" do
    # ⚠️ Bluesky counts graphemes. `String#length` gives UTF-16 code units, thus it counts one
    # emoji as 2 or more. social_controller.js counts the same way with Intl.Segmenter.
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
      expect(described_class::MAX_GRAPHEMES).to eq(SocialPresenter::BODY_LIMIT)
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

    # ⚠️ It answers with the reference as well as the URL. The next post of a thread names this one
    # by its `uri` and its `cid`, and an at:// URI holds no CID.
    it "writes the post and answers with its reference and its public URL" do
      result = service.post!(rkey: "3kabc", text: "A long day.")

      expect(result["url"]).to eq("https://bsky.app/profile/me.bsky.social/post/3kabc")
      expect(result["uri"]).to eq("at://did:plc:abc/app.bsky.feed.post/3kabc")
      expect(result["cid"]).to eq("bafypost")
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
        stub_streamed_get("https://cdn.test/og.png", body: "bytes", headers: { "content-type" => "image/png" })
        allow(HTTParty).to receive(:post)
          .with(a_string_including("com.atproto.repo.uploadBlob"), anything)
          .and_return(instance_double(HTTParty::Response, success?: true, code: 200,
                                      body: { blob: { "$type" => "blob" } }.to_json))
      end

      # Captures the blob that uploadBlob sent, so an example can read it.
      def stub_upload_blob
        uploaded = nil
        allow(HTTParty).to receive(:post)
          .with(a_string_including("com.atproto.repo.uploadBlob"), anything) do |_url, options|
            uploaded = options
            instance_double(HTTParty::Response, success?: true, code: 200,
                            body: { blob: { "$type" => "blob" } }.to_json)
          end
        -> { uploaded }
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

      describe "the standard.site refs" do
        let(:document_uri) { "at://did:plc:abc/site.standard.document/doc1" }
        let(:publication_uri) { "at://did:plc:abc/site.standard.publication/pub1" }
        let(:standard_card) do
          OpenGraph::Card.new(url: "https://example.test/post/", title: "A title",
                              description: "A summary.", image_url: nil,
                              document_uri: document_uri, publication_uri: publication_uri)
        end

        def stub_get_record(cids = { "doc1" => "bafydoc", "pub1" => "bafypub" })
          allow(HTTParty).to receive(:get)
            .with(a_string_including("com.atproto.repo.getRecord"), anything) do |_url, options|
              rkey = options[:query][:rkey]
              cid = cids[rkey]
              instance_double(HTTParty::Response, success?: cid.present?, code: cid ? 200 : 404,
                              body: { uri: "at://did:plc:abc/x/#{rkey}", cid: cid }.to_json,
                              request: nil)
            end
        end

        # ⚠️ This is what makes Bluesky render the standard.site card and not the ordinary one. The
        # embed stays an app.bsky.embed.external, and associatedRefs is what it adds.
        it "adds the document and the publication, in that order" do
          stub_get_record

          service.post!(rkey: "3kabc", text: "Read this", card: standard_card)

          refs = @sent["record"]["embed"]["external"]["associatedRefs"]
          expect(@sent["record"]["embed"]["$type"]).to eq("app.bsky.embed.external")
          expect(refs).to eq([
            { "uri" => "at://did:plc:abc/x/doc1", "cid" => "bafydoc" },
            { "uri" => "at://did:plc:abc/x/pub1", "cid" => "bafypub" }
          ])
        end

        # ⚠️ A strongRef needs the CID, and an at:// URI does not hold one. Thus the code must read
        # each record.
        it "reads each record from the PDS of the repo" do
          stub_get_record

          service.post!(rkey: "3kabc", text: "Read this", card: standard_card)

          expect(HTTParty).to have_received(:get).with(
            "https://pds.test/xrpc/com.atproto.repo.getRecord",
            hash_including(query: { repo: "did:plc:abc", collection: "site.standard.document",
                                    rkey: "doc1" })
          )
        end

        # A page on another site publishes no such tag. Bluesky then renders the ordinary card.
        it "adds no refs for a page with no standard.site tags" do
          service.post!(rkey: "3kabc", text: "Read this", card: card)

          expect(@sent["record"]["embed"]["external"]).not_to have_key("associatedRefs")
        end

        # ⚠️ It falls back with no message, on purpose: an ordinary card is still a good card.
        it "falls back to the ordinary card when the record cannot be read" do
          stub_get_record({})

          service.post!(rkey: "3kabc", text: "Read this", card: standard_card)

          expect(@sent["record"]["embed"]["external"]).not_to have_key("associatedRefs")
          expect(@sent["record"]["embed"]["external"]["uri"]).to eq("https://example.test/post/")
        end

        # ⚠️ The publication tag is on each page of a site, and the document is the thing that names
        # one article. Thus the publication alone is not a card.
        it "adds nothing when only the publication resolves" do
          stub_get_record({ "pub1" => "bafypub" })

          service.post!(rkey: "3kabc", text: "Read this", card: standard_card)

          expect(@sent["record"]["embed"]["external"]).not_to have_key("associatedRefs")
        end

        it "keeps the document alone when the publication cannot be read" do
          stub_get_record({ "doc1" => "bafydoc" })

          service.post!(rkey: "3kabc", text: "Read this", card: standard_card)

          expect(@sent["record"]["embed"]["external"]["associatedRefs"].size).to eq(1)
        end

        # ⚠️ A PDS answers getRecord for its own repos only, thus another DID needs its DID document
        # first. did:web gives nil here, and the card is then the ordinary one.
        it "makes no ref for a DID method that it cannot resolve" do
          card = OpenGraph::Card.new(url: "https://other.test/post/", title: "T", description: "D",
                                     image_url: nil,
                                     document_uri: "at://did:web:other.test/site.standard.document/d")

          service.post!(rkey: "3kabc", text: "Read this", card: card)

          expect(@sent["record"]["embed"]["external"]).not_to have_key("associatedRefs")
        end
      end

      # ⚠️ The link is the card, and it is not in the text. Thus the URL uses none of the 300
      # characters.
      it "keeps the URL out of the text" do
        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(@sent["record"]["text"]).to eq("Read this")
      end

      # A card with no picture still renders. Thus a failed image must never lose the post.
      it "still posts when the image fails" do
        stub_streamed_get("https://cdn.test/og.png", body: "", code: 500)

        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(@sent["record"]["embed"]["external"]).not_to have_key("thumb")
      end

      it "asks for the picture with its own user agent and a timeout" do
        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(HTTParty).to have_received(:get).with(
          "https://cdn.test/og.png",
          hash_including(headers: hash_including("User-Agent" => OpenGraph::USER_AGENT),
                         open_timeout: OpenGraph::OPEN_TIMEOUT, read_timeout: OpenGraph::READ_TIMEOUT)
        )
      end

      # ⚠️ The picture belongs to a page that the owner linked to, and the worker is a 512MB VM. A
      # picture past the download limit loses the thumbnail, and never the post.
      it "drops a picture past the download limit and still posts" do
        stub_streamed_get("https://cdn.test/og.png", body: "x" * (described_class::MAX_CARD_IMAGE_BYTES + 1),
                          headers: { "content-type" => "image/png" }, fragments: 4)
        uploaded = stub_upload_blob

        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(uploaded.call).to be_nil
        expect(@sent["record"]["embed"]["external"]).not_to have_key("thumb")
      end

      # A 200 that is an HTML error page must not go up as a picture.
      it "drops a body that is not an image" do
        stub_streamed_get("https://cdn.test/og.png", body: "<html>Not found</html>",
                          headers: { "content-type" => "text/html" })
        uploaded = stub_upload_blob

        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(uploaded.call).to be_nil
        expect(@sent["record"]["embed"]["external"]).not_to have_key("thumb")
      end

      # A host with no Content-Type still serves a true picture. The decode is the check.
      it "decodes a picture that comes with no content type" do
        stub_streamed_get("https://cdn.test/og.png", body: "bytes")
        allow(Vips::Image).to receive(:new_from_buffer).and_return(Vips::Image.black(100, 50))
        uploaded = stub_upload_blob

        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(uploaded.call[:headers]["Content-Type"]).to eq("image/jpeg")
        expect(@sent["record"]["embed"]["external"]["thumb"]).to eq({ "$type" => "blob" })
      end

      # ⚠️ A blob past the limit fails at putRecord and takes the whole post with it. A picture
      # that stays too large after the shrink must go away, and the post must not.
      it "drops a picture that is still past the blob limit after the shrink" do
        stub_streamed_get("https://cdn.test/og.png", body: "x" * (described_class::MAX_BLOB_BYTES + 1),
                          headers: { "content-type" => "image/png" })
        # A plain double: ruby-vips makes `jpegsave_buffer` at run time, thus an instance_double
        # cannot see it.
        still_big = double("Vips::Image", width: 100, jpegsave_buffer: "j" * (described_class::MAX_BLOB_BYTES + 1))
        allow(Vips::Image).to receive(:new_from_buffer).and_return(still_big)
        uploaded = stub_upload_blob

        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(uploaded.call).to be_nil
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

      # ⚠️ libvips is a native library, and the require is inside #shrink and not at the top of the
      # file. Thus a post with a picture that needs no shrink never needs libvips at all, and a
      # machine without it gets a card with no picture in place of a 500. LoadError is not a
      # StandardError, thus the rescue there names it.
      it "posts with no picture on a machine that has no libvips" do
        big = "x" * (described_class::MAX_BLOB_BYTES + 1)
        allow(HTTParty).to receive(:get)
          .with("https://cdn.test/og.png", anything)
          .and_return(instance_double(HTTParty::Response, success?: true, body: big, code: 200,
                                      headers: { "content-type" => "image/png" }))
        allow_any_instance_of(described_class).to receive(:require).with("vips")
          .and_raise(LoadError, "cannot load such file -- vips")

        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(@sent["record"]["embed"]["external"]).not_to have_key("thumb")
        expect(@sent["record"]["text"]).to eq("Read this")
      end

      # ⚠️ A blob past the limit fails at putRecord and not at the upload, thus the whole post
      # would go away and the message would name the embed.
      it "shrinks a picture that is over the blob limit" do
        stub_streamed_get("https://cdn.test/og.png", body: "x" * (described_class::MAX_BLOB_BYTES + 1),
                          headers: { "content-type" => "image/png" })
        # A true image, thus the resize and the JPEG encode really run. The download is the only
        # stub: the body stands for a file that is too large, and libvips never decodes it.
        allow(Vips::Image).to receive(:new_from_buffer).and_return(Vips::Image.black(2400, 1200))
        uploaded = stub_upload_blob

        service.post!(rkey: "3kabc", text: "Read this", card: card)

        expect(uploaded.call[:body].bytesize).to be < described_class::MAX_BLOB_BYTES
        expect(uploaded.call[:headers]["Content-Type"]).to eq("image/jpeg")
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

      # ⚠️ Two facets over one range render as a broken link. A mention inside a URL is part of
      # the URL, and the PDS never hears about it.
      it "leaves a mention inside a link alone" do
        allow(HTTParty).to receive(:get).with(a_string_including("resolveHandle"), anything)

        service.post!(rkey: "3kabc", text: "See https://bsky.app/profile/@me.bsky.social now")

        types = @sent["record"]["facets"].map { |facet| facet["features"].first["$type"] }
        expect(types).to eq([ "app.bsky.richtext.facet#link" ])
        expect(HTTParty).not_to have_received(:get).with(a_string_including("resolveHandle"), anything)
      end

      it "leaves a tag inside a link alone" do
        service.post!(rkey: "3kabc", text: "See https://example.test/#results and #ironman")

        tags = @sent["record"]["facets"].filter_map { |facet| facet["features"].first["tag"] }
        expect(tags).to eq([ "ironman" ])
      end

      # The client of Bluesky does not count "#1" as a tag either.
      it "does not mark a number as a tag" do
        service.post!(rkey: "3kabc", text: "Finished #1 in my age group")

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
