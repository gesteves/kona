require "rails_helper"

RSpec.describe SocialDraftValidator do
  def network(key, connected: true)
    SocialPresenter::Network.new(key: key, name: I18n.t("admin.networks.#{key}"), connected: connected)
  end

  # @param params [Hash] The parameters of the request. Bluesky is ticked by default.
  # @return [String, nil] The error of the draft.
  def error_of(networks: %w[bluesky], **params)
    accounts = [ network("bluesky"), network("mastodon"), network("threads") ]
    draft = SocialDraft.new(ActionController::Parameters.new(networks: networks, **params), networks: accounts)
    described_class.new(draft).error
  end

  def message(key, **options) = I18n.t("admin.social.errors.#{key}", **options)

  def post(text, **rest) = { text: text, link: "", **rest }

  # The handle check must not reach the network in an example that is not about it.
  before { allow_any_instance_of(Bluesky).to receive(:handle_missing?).and_return(false) }

  it "takes a draft with words and a ticked network" do
    expect(error_of(posts: [ post("Hello") ])).to be_nil
  end

  it "refuses a draft with no post, and one with too many" do
    expect(error_of(posts: [])).to eq(message("empty"))

    many = Array.new(SocialPresenter::MAX_POSTS + 1) { |i| post("Post #{i}") }
    expect(error_of(posts: many)).to eq(message("too_many_posts", count: SocialPresenter::MAX_POSTS))
  end

  # ⚠️ Each form is a complete sentence: a draft of one post says "That post", and a thread names
  # the post by its number.
  it "names the post of a thread by its number, and a single post by no number" do
    expect(error_of(posts: [ { text: "", link: "https://example.test/x" } ]))
      .to eq(message("text_missing.single", index: 1))
    expect(error_of(posts: [ post("One"), { text: "", link: "https://example.test/x" } ]))
      .to eq(message("text_missing.numbered", index: 2))
  end

  describe "the length" do
    it "refuses a post past the limit of Bluesky" do
      text = "a" * (Bluesky::MAX_GRAPHEMES + 1)

      expect(error_of(posts: [ post(text) ]))
        .to eq(message("too_long.single", index: 1, count: Bluesky::MAX_GRAPHEMES + 1, limit: Bluesky::MAX_GRAPHEMES))
    end

    # ⚠️ It counts the text that Bluesky will get: a mention grows into a handle.
    it "says so when the handles of Bluesky are what put the post past the limit" do
      text = "#{'a' * (Bluesky::MAX_GRAPHEMES - 6)} @tony"
      mentions = [ { token: "@tony", bluesky: "tony.bsky.social" } ]

      expect(error_of(posts: [ post(text) ], mentions: mentions))
        .to eq(message("too_long_handles.single", index: 1, count: text.length + ".bsky.social".length,
                                                  limit: Bluesky::MAX_GRAPHEMES))
    end

    # ⚠️ A plain name can be much longer than a handle, thus the text of each network has its own
    # length.
    it "refuses a post past the limit of Mastodon alone" do
      mentions = [ { token: "@tony", mastodon: "n" * Mastodon::DEFAULT_MAX_CHARACTERS } ]

      expect(error_of(posts: [ post("With @tony") ], mentions: mentions))
        .to eq(message("too_long_mastodon.single", index: 1))
    end
  end

  it "refuses a link that is not http or https" do
    expect(error_of(posts: [ { text: "Hello", link: "ftp://example.test/x" } ]))
      .to eq(message("bad_link.single", index: 1))
  end

  describe "the photos" do
    let(:stored) { SocialPhotos.new.store(image: "\xFF\xD8\xFF\xE0jpeg".b, width: 2, height: 1) }

    after { SocialPhotos.new.discard([ stored ]) }

    it "takes a post with a photo that is in the store" do
      expect(error_of(posts: [ post("A photo", photos: [ stored ], alts: [ "A dog." ]) ])).to be_nil
    end

    # ⚠️ Bluesky renders one embed, thus a post takes photos OR a link.
    it "refuses a post with photos and a link" do
      expect(error_of(posts: [ { text: "Both", link: "https://example.test/x", photos: [ stored ] } ]))
        .to eq(message("photos_and_link.single", index: 1))
    end

    it "refuses an alt text past its limit" do
      alt = "a" * (SocialPresenter::ALT_LIMIT + 1)

      expect(error_of(posts: [ post("A photo", photos: [ stored ], alts: [ alt ]) ]))
        .to eq(message("alt_too_long.single", index: 1, count: alt.length, limit: SocialPresenter::ALT_LIMIT))
    end

    # ⚠️ The 24-hour draft TTL removed it. Without this check the job fails the post later.
    it "refuses a photo that is gone from the store" do
      expect(error_of(posts: [ post("A photo", photos: [ "b" * 32 ]) ]))
        .to eq(message("photo_missing.single", index: 1))
    end

    it "refuses a ticked network that takes fewer photos than one post holds" do
      ids = Array.new(Mastodon::MAX_MEDIA_ATTACHMENTS + 1) { SocialPhotos.new.store(image: "jpeg".b, width: 1, height: 1) }

      expect(error_of(networks: %w[bluesky mastodon], posts: [ post("Photos", photos: ids) ]))
        .to eq(message("photos_network", networks: I18n.t("admin.networks.mastodon")))
    ensure
      SocialPhotos.new.discard(ids)
    end
  end

  describe "the networks" do
    it "refuses a draft with no ticked network that has an account" do
      expect(error_of(networks: [], posts: [ post("Hello") ])).to eq(message("no_network"))
      expect(error_of(networks: %w[myspace], posts: [ post("Hello") ])).to eq(message("no_network"))
    end

    # ⚠️ Mastodon and Threads post plain words, thus the link would go out as its own syntax.
    it "refuses a Markdown link that goes to a network with no rich text" do
      posts = [ post("A [link](https://example.test/x)") ]

      expect(error_of(networks: %w[bluesky], posts: posts)).to be_nil
      expect(error_of(networks: %w[bluesky threads], posts: posts))
        .to eq(message("markdown_network", networks: I18n.t("admin.networks.threads")))
    end

    # ⚠️ The field stays in the form while the Threads row is not ticked.
    it "refuses a bad topic only when Threads is ticked" do
      topic = "a" * (Threads::TOPIC_MAX_CHARACTERS + 1)

      expect(error_of(networks: %w[bluesky], posts: [ post("Hello") ], topic: topic)).to be_nil
      expect(error_of(networks: %w[threads], posts: [ post("Hello") ], topic: topic))
        .to eq(message("bad_topic", limit: Threads::TOPIC_MAX_CHARACTERS))
    end
  end

  describe "the mentions" do
    # ⚠️ A Mastodon handle is not a Bluesky domain, thus without this it becomes plain words.
    it "refuses a field that holds the handle of a different network" do
      mentions = [ { token: "@tony", bluesky: "@tony@mastodon.social" } ]

      expect(error_of(posts: [ post("With @tony") ], mentions: mentions))
        .to eq(message("mistaken_network", network: I18n.t("admin.networks.bluesky"), token: "@tony",
                                           other: I18n.t("admin.networks.mastodon")))
    end

    it "refuses a Bluesky handle that the PDS does not know" do
      allow_any_instance_of(Bluesky).to receive(:handle_missing?).with("tony.bsky.social").and_return(true)
      mentions = [ { token: "@tony", bluesky: "tony.bsky.social" } ]

      expect(error_of(posts: [ post("With @tony") ], mentions: mentions))
        .to eq(message("bad_handle", handle: "tony.bsky.social"))
    end

    it "asks Bluesky about no handle when the owner does not post there" do
      expect_any_instance_of(Bluesky).not_to receive(:handle_missing?)
      mentions = [ { token: "@tony", bluesky: "tony.bsky.social" } ]

      expect(error_of(networks: %w[threads], posts: [ post("With @tony") ], mentions: mentions)).to be_nil
    end

    # ⚠️ The budget, and not the timeout of one call, keeps this check away from the rack-timeout.
    it "stops the handle check at its budget, and then takes the draft" do
      stub_const("SocialDraftValidator::HANDLE_CHECK_BUDGET", 0)
      expect_any_instance_of(Bluesky).not_to receive(:handle_missing?)
      mentions = [ { token: "@tony", bluesky: "tony.bsky.social" } ]

      expect(error_of(posts: [ post("With @tony") ], mentions: mentions)).to be_nil
    end
  end

  describe "the schedule" do
    it "refuses an open schedule with no moment" do
      expect(error_of(posts: [ post("Hello") ], schedule: "1", date: "", time: "")).to eq(message("no_moment"))
    end

    # ⚠️ It is not a schedule, thus the post goes out at once.
    it "takes a moment that passed" do
      expect(error_of(posts: [ post("Hello") ], schedule: "1", date: "2020-01-01", time: "09:00")).to be_nil
    end
  end
end
