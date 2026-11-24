require "rails_helper"

RSpec.describe SocialPreview do
  let(:link) { "https://example.test/post" }
  let(:open_graph) { instance_double(OpenGraph) }
  let(:photo_id) { "a" * 32 }

  before { allow(OpenGraph).to receive(:new).and_return(open_graph) }

  def network(key, connected: true)
    SocialPresenter::Network.new(key: key, name: key.capitalize, connected: connected)
  end

  def card(title: "A title", image_url: nil, document_uri: nil)
    OpenGraph::Card.new(url: link, title: title, description: "Words", image_url: image_url,
                        document_uri: document_uri)
  end

  # @param accounts [Array<SocialPresenter::Network>] The networks of the page, with their state.
  # @param params [Hash] The parameters of the request.
  def preview(accounts: [ network("bluesky"), network("mastodon"), network("threads") ], **params)
    draft = SocialDraft.new(ActionController::Parameters.new(params), networks: accounts)
    described_class.new(draft: draft, photo_path: ->(id) { "/photos/#{id}" },
                        image_path: ->(url) { "/image?url=#{url}" })
  end

  describe "#networks" do
    it "shows each connected network, and no other" do
      shown = preview(accounts: [ network("bluesky"), network("mastodon", connected: false), network("threads") ],
                      posts: [ { text: "Hello", link: "" } ]).networks

      expect(shown.map { |row| row[:key] }).to eq(%w[bluesky threads])
      expect(shown.first).to include(name: "Bluesky")
    end

    # ⚠️ To render another network would show a text that this app refuses to post.
    it "shows Bluesky alone for a draft with a Markdown link" do
      shown = preview(posts: [ { text: "A [link](https://example.test/x)", link: "" } ]).networks

      expect(shown.map { |row| row[:key] }).to eq(%w[bluesky])
    end

    it "shows only the networks that take the photos of the largest post" do
      ids = Array.new(Mastodon::MAX_MEDIA_ATTACHMENTS + 1) { |i| format("%032x", i) }
      shown = preview(posts: [ { text: "Photos", link: "", photos: ids } ]).networks

      expect(shown.map { |row| row[:key] }).to eq(%w[bluesky threads])
    end

    it "gives the posts of a network in the order of the thread" do
      shown = preview(posts: [ { text: "One", link: "" }, { text: "Two", link: "" } ]).networks

      expect(shown.first[:posts].map { |post| post[:text] }).to eq(%w[One Two])
    end
  end

  describe "one post" do
    def post_of(key, **params) = preview(**params).networks.find { |row| row[:key] == key }[:posts].first

    it "gives the text, its length, and the limit of that network" do
      post = post_of("threads", posts: [ { text: "Hello", link: "" } ])

      expect(post).to include(text: "Hello", length: 5, limit: Threads::MAX_CHARACTERS, over: false,
                              segments: [ { text: "Hello" } ], topic: nil, link: nil, card: nil, photos: nil)
    end

    it "says when a post is past the limit of the network" do
      post = post_of("bluesky", posts: [ { text: "a" * (Bluesky::MAX_GRAPHEMES + 1), link: "" } ])

      expect(post).to include(length: Bluesky::MAX_GRAPHEMES + 1, over: true)
    end

    # ⚠️ A Markdown link shows its WORDS, thus the segment is the only thing that says where they
    # point.
    it "gives each link of the text as a segment with its address" do
      post = post_of("bluesky", posts: [ { text: "Read [my post](https://example.test/x) now", link: "" } ])

      expect(post[:text]).to eq("Read my post now")
      expect(post[:segments]).to eq([ { text: "Read " }, { text: "my post", url: "https://example.test/x" },
                                      { text: " now" } ])
    end

    it "puts the topic on the Threads row alone" do
      params = { posts: [ { text: "Hello", link: "" } ], topic: "#Triathlon" }

      expect(post_of("threads", **params)[:topic]).to eq("Triathlon")
      expect(post_of("bluesky", **params)[:topic]).to be_nil
    end

    describe "with a link" do
      let(:params) { { posts: [ { text: "Read this", link: link } ] } }

      before { allow(open_graph).to receive(:fetch).with(link).and_return(card(image_url: "https://cdn.test/og.png")) }

      it "draws the card on the Bluesky row, with the path of the picture proxy" do
        post = post_of("bluesky", **params)

        expect(post[:text]).to eq("Read this")
        expect(post[:card]).to eq(url: link, title: "A title", description: "Words", host: "example.test",
                                  image_path: "/image?url=#{link}", standard_site: false, embeddable: true)
        expect(post[:link]).to be_nil
      end

      # ⚠️ Threads makes an attachment that this app cannot draw, thus the row shows the address.
      it "shows the address below the words on the Threads row, and no card" do
        post = post_of("threads", **params)

        expect(post).to include(text: "Read this", link: link, card: nil)
      end

      it "puts the link in the words of the Mastodon row" do
        post = post_of("mastodon", **params)

        expect(post[:text]).to eq(SocialText.compose(text: "Read this", url: link))
        expect(post[:segments]).to include({ text: link, url: link })
      end

      # ⚠️ Bluesky renders no embed for such a page, thus the panel draws no card and the link is
      # in the words.
      it "draws no card for a page with no og: tags" do
        allow(open_graph).to receive(:fetch).with(link)
          .and_return(OpenGraph::Card.new(url: link, title: nil, description: nil, image_url: nil))

        post = post_of("bluesky", **params)

        expect(post[:card]).to be_nil
        expect(post[:text]).to include(link)
      end
    end

    it "gives the photos of a post with the path of each one" do
      post = post_of("bluesky", posts: [ { text: "A photo", link: "", photos: [ photo_id ], alts: [ "A dog." ] } ])

      expect(post[:photos]).to eq([ { path: "/photos/#{photo_id}", alt: "A dog." } ])
    end
  end

  describe "#card_json" do
    it "reads the page one time, however many times the card is asked for" do
      allow(open_graph).to receive(:fetch).with(link).and_return(card)
      built = preview

      2.times { built.card_json(link) }

      expect(open_graph).to have_received(:fetch).once
    end

    it "gives no picture path for a page with no picture, and marks a standard.site page" do
      allow(open_graph).to receive(:fetch).with(link).and_return(card(document_uri: "at://did:plc:x/site.standard.document/1"))

      expect(preview.card_json(link)).to include(image_path: nil, standard_site: true)
    end
  end
end
