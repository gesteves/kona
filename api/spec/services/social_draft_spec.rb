require "rails_helper"

RSpec.describe SocialDraft do
  include ActiveSupport::Testing::TimeHelpers

  let(:photo_id) { "a" * 32 }

  def network(key, connected: true)
    SocialPresenter::Network.new(key: key, name: key.capitalize, connected: connected)
  end

  # @param accounts [Array<SocialPresenter::Network>] The networks of the page, with their state.
  # @param params [Hash] The parameters of the request.
  def draft(accounts: [ network("bluesky"), network("mastodon"), network("threads") ], **params)
    described_class.new(ActionController::Parameters.new(params), networks: accounts)
  end

  def card(url, title: "A title")
    OpenGraph::Card.new(url: url, title: title, description: nil, image_url: nil)
  end

  describe "#posts" do
    it "strips each field one time, and drops a block with nothing in it" do
      posts = draft(posts: [ { text: "  Hello \n", link: " https://example.test/x " }, { text: " ", link: "" } ]).posts

      expect(posts).to eq([ { text: "Hello", link: "https://example.test/x", photos: [] } ])
    end

    # ⚠️ A form with no block sends an empty `posts[]`, which arrives as a string.
    it "drops a block that is not a hash" do
      expect(draft(posts: [ "", { text: "Hello", link: "" } ]).posts.length).to eq(1)
    end

    # ⚠️ The two arrays match by POSITION. A drop of the id alone would move each alt text after it
    # by one.
    it "pairs each photo with its alt text before it drops an id with the wrong shape" do
      posts = draft(posts: [ { text: "", link: "", photos: [ "", photo_id, "../etc" ],
                               alts: [ "Lost", " Kept ", "Lost too" ] } ]).posts

      expect(posts.first[:photos]).to eq([ { id: photo_id, alt: "Kept" } ])
    end

    it "gives the id of each photo of the draft" do
      other = "b" * 32
      built = draft(posts: [ { text: "One", link: "", photos: [ photo_id ] },
                             { text: "Two", link: "", photos: [ other ] } ])

      expect(built.photo_ids).to eq([ photo_id, other ])
    end
  end

  describe "#mention_rows and #values_for" do
    let(:built) do
      draft(mentions: [ "", { token: " @Tony ", bluesky: "tony.bsky.social", mastodon: " ", threads: "@tony" },
                        { token: "", bluesky: "nobody.test" } ])
    end

    it "drops a row that is not a hash and a row with no token" do
      expect(built.mention_rows.map { |row| row[:token] }).to eq([ "@Tony" ])
    end

    # ⚠️ A blank field is absent, thus SocialMentions removes the "@" of the token for that network.
    it "gives the field of one network by mention key, with no blank value" do
      expect(built.values_for("bluesky")).to eq({ "tony" => "tony.bsky.social" })
      expect(built.values_for("mastodon")).to eq({})
    end
  end

  describe "#selected_networks" do
    # ⚠️ A row with no account renders disabled, and a request that a person writes can tick it.
    it "keeps only a ticked network that this app knows and that has an account" do
      built = draft(networks: %w[bluesky mastodon myspace],
                    accounts: [ network("bluesky"), network("mastodon", connected: false), network("threads") ])

      expect(built.selected_networks).to eq(%w[bluesky])
    end

    it "gives the names of a list of keys, in a sentence" do
      expect(draft.names_of(%w[bluesky threads])).to eq("Bluesky and Threads")
    end
  end

  describe "#text_for" do
    # ⚠️ The mentions go in first, and the typography second.
    it "puts the mention of that network in, then applies the typography" do
      built = draft(mentions: [ { token: "@tony", bluesky: "tony.bsky.social", mastodon: "Anthony Edwards" } ])

      expect(built.text_for("bluesky", %(A "ride" with @tony...))).to eq("A “ride” with @tony.bsky.social…")
      expect(built.text_for("mastodon", "With @tony.")).to eq("With Anthony Edwards.")
      expect(built.text_for("threads", "With @tony.")).to eq("With tony.")
    end
  end

  describe "#bluesky_text and #card_for" do
    let(:link) { "https://example.test/post" }
    let(:open_graph) { instance_double(OpenGraph) }

    before { allow(OpenGraph).to receive(:new).and_return(open_graph) }

    it "keeps the link out of the text for a page that gives a card" do
      allow(open_graph).to receive(:fetch).with(link).and_return(card(link))
      built = draft

      expect(built.bluesky_text({ text: "Read this", link: link })).to eq("Read this")
      expect(built.bluesky_link_in_text({ text: "Read this", link: link })).to be_nil
    end

    # ⚠️ Bluesky renders no embed for such a page, thus the link goes in the words and the count
    # must hold it.
    it "puts the link in the text for a page with no og: tags" do
      allow(open_graph).to receive(:fetch).with(link).and_return(card(link, title: nil))

      expect(draft.bluesky_text({ text: "Read this", link: link })).to eq(Bluesky.compose(text: "Read this", url: link))
    end

    it "reads each page one time for the whole draft" do
      allow(open_graph).to receive(:fetch).with(link).and_return(card(link))
      built = draft

      3.times { built.card_for(link) }

      expect(open_graph).to have_received(:fetch).once
    end

    # ⚠️ Several slow reads together pass the rack-timeout, which no rescue catches.
    it "gives a blank card, and reads nothing, after the budget of the request is gone" do
      stub_const("SocialDraft::CARD_READ_BUDGET", 0)
      allow(open_graph).to receive(:fetch)
      allow(open_graph).to receive(:blank_card).with(link).and_return(card(link, title: nil))

      expect(draft.card_for(link)).not_to be_embeddable
      expect(open_graph).not_to have_received(:fetch)
    end
  end

  describe "#length_for and #over_limit?" do
    it "counts by the rule of each network" do
      post = { text: "Hello", link: "", photos: [] }
      built = draft

      expect(built.length_for("bluesky", post)).to eq(5)
      expect(built.length_for("threads", post)).to eq(5)
      expect(built.over_limit?("threads", post)).to be(false)
      expect(built.over_limit?("threads", post.merge(text: "a" * (Threads::MAX_CHARACTERS + 1)))).to be(true)
    end
  end

  describe "#markdown? and #takes_photos?" do
    it "reads the whole thread, thus one post decides the draft" do
      built = draft(posts: [ { text: "Plain", link: "" }, { text: "A [link](https://example.test/x)", link: "" } ])

      expect(built.markdown?).to be(true)
      expect(draft(posts: [ { text: "Plain", link: "" } ]).markdown?).to be(false)
    end

    it "takes the largest post against the photo limit of a network" do
      ids = Array.new(Mastodon::MAX_MEDIA_ATTACHMENTS + 1) { |i| format("%032x", i) }
      built = draft(posts: [ { text: "Photos", link: "", photos: ids } ])

      expect(built.most_photos).to eq(ids.length)
      expect(built.takes_photos?("bluesky")).to be(true)
      expect(built.takes_photos?("mastodon")).to be(false)
      expect(built.takes_photos?("myspace")).to be(false)
    end
  end

  describe "#payload" do
    let(:built) do
      draft(posts: [ { text: "With @tony", link: "https://example.test/x" },
                     { text: "Photos", link: "", photos: [ photo_id ], alts: [ "A dog." ] } ],
            mentions: [ { token: "@tony", bluesky: "tony.bsky.social", threads: "@tony" } ],
            topic: "#Triathlon")
    end

    # ⚠️ The key of a post is the same at each network, and the text is not.
    it "gives each network its own text and the same key for each post" do
      bluesky = built.payload("bluesky", %w[k1 k2])
      threads = built.payload("threads", %w[k1 k2])

      expect(bluesky.map { |post| post["key"] }).to eq(%w[k1 k2])
      expect(threads.map { |post| post["key"] }).to eq(%w[k1 k2])
      expect(bluesky.first).to eq({ "key" => "k1", "text" => "With @tony.bsky.social", "link" => "https://example.test/x" })
      expect(threads.first["text"]).to eq("With @tony")
    end

    it "puts the topic on each post of Threads alone" do
      expect(built.payload("threads", %w[k1 k2]).map { |post| post["topic"] }).to eq(%w[Triathlon Triathlon])
      expect(built.payload("bluesky", %w[k1 k2])).to all(satisfy { |post| !post.key?("topic") })
    end

    it "puts the photos on the post that holds them, and on no other" do
      payload = built.payload("mastodon", %w[k1 k2])

      expect(payload.first).not_to have_key("photos")
      expect(payload.last["photos"]).to eq([ { "id" => photo_id, "alt" => "A dog." } ])
    end
  end

  describe "the schedule" do
    it "has no moment while the schedule fields are closed" do
      built = draft(date: "2026-12-01", time: "09:00")

      expect(built.scheduled?).to be(false)
      expect(built.picked_moment).to be_nil
    end

    it "reads the two fields in the zone that the browser sent" do
      built = draft(schedule: "1", date: "2026-12-01", time: "09:00", time_zone: "America/New_York")

      travel_to(Time.utc(2026, 11, 20)) do
        expect(built.schedule_zone).to eq("America/New_York")
        expect(built.scheduled_at).to eq(Time.utc(2026, 12, 1, 14, 0))
      end
    end

    # ⚠️ `Time.zone.parse` reads "garbage 09:00" as today at 09:00.
    it "has no moment for a field with the wrong shape" do
      expect(draft(schedule: "1", date: "garbage", time: "09:00").picked_moment).to be_nil
      expect(draft(schedule: "1", date: "2026-12-01", time: "").picked_moment).to be_nil
    end

    it "uses the default zone for a zone that Rails does not know" do
      expect(draft(time_zone: "Mars/Olympus").schedule_zone).to eq(TimeZoneResolver.default)
    end

    # ⚠️ A moment that passed is not a schedule: the post goes out at once.
    it "keeps a moment that passed as the picked one, and schedules nothing for it" do
      built = draft(schedule: "1", date: "2026-01-01", time: "09:00", time_zone: "UTC")

      travel_to(Time.utc(2026, 11, 20)) do
        expect(built.picked_moment).to eq(Time.utc(2026, 1, 1, 9, 0))
        expect(built.scheduled_at).to be_nil
      end
    end
  end
end
