require "rails_helper"

RSpec.describe SharePostJob do
  let(:bluesky) { instance_double(Bluesky) }
  let(:mastodon) { instance_double(Mastodon) }
  let(:open_graph) { instance_double(OpenGraph) }
  let(:url) { "https://example.test/2026/07/12/ic/" }
  let(:card) do
    OpenGraph::Card.new(url: url, title: "Ironman Canada", description: "A long day.",
                        image_url: "https://cdn.test/og.png")
  end

  before do
    allow(Bluesky).to receive(:new).and_return(bluesky)
    allow(bluesky).to receive(:post!).and_return("https://bsky.app/profile/me/post/3kabc")
    allow(Mastodon).to receive(:new).and_return(mastodon)
    allow(mastodon).to receive(:post!).and_return("https://instance.test/@me/1")
    allow(OpenGraph).to receive(:new).and_return(open_graph)
    allow(open_graph).to receive(:fetch).and_return(card)
  end

  # ⚠️ The card comes from the og: tags of the page, and not from Contentful. A Short has no cover
  # image, and the link can also be a page on another site.
  it "posts to Bluesky with the card of the linked page" do
    described_class.new.perform("3kabc", url, "Read this", [ "bluesky" ])

    expect(open_graph).to have_received(:fetch).with(url)
    expect(bluesky).to have_received(:post!).with(rkey: "3kabc", text: "Read this", card: card)
  end

  # ⚠️ Mastodon renders the link inline and makes its own preview card. Thus the URL goes to it as
  # a plain argument, and this job reads no og: tags for it.
  it "posts to Mastodon with the link and no card" do
    described_class.new.perform("3kabc", url, "Read this", [ "mastodon" ])

    expect(mastodon).to have_received(:post!)
      .with(text: "Read this", url: url, idempotency_key: "3kabc")
    expect(open_graph).not_to have_received(:fetch)
  end

  it "posts to both when the owner ticks both" do
    described_class.new.perform("3kabc", url, "Hi", %w[bluesky mastodon])

    expect(bluesky).to have_received(:post!).once
    expect(mastodon).to have_received(:post!).once
  end

  it "shares a link to another site" do
    other = "https://someone-else.test/a-post/"
    described_class.new.perform("3kabc", other, "Good read", [ "bluesky" ])

    expect(open_graph).to have_received(:fetch).with(other)
  end

  # ⚠️ Threads has its token and its write scope, and no code sends to it. A key that no code sends
  # to is a skip and never an error, thus a draft that names one does not go into the Dead set.
  it "skips a network that is not wired up yet" do
    described_class.new.perform("3kabc", url, "Hi", %w[bluesky threads])

    expect(bluesky).to have_received(:post!).once
  end

  it "does nothing when no network is wired up yet" do
    described_class.new.perform("3kabc", url, "Hi", [ "threads" ])

    expect(bluesky).not_to have_received(:post!)
    expect(mastodon).not_to have_received(:post!)
    expect(open_graph).not_to have_received(:fetch)
  end

  describe "when one network fails" do
    before { allow(bluesky).to receive(:post!).and_raise("Bluesky refused the post") }

    # ⚠️ It tries each network before it raises. One service that is away must not stop the other
    # one, and the idempotency of each network makes the retry safe.
    it "still posts to the other one" do
      expect { described_class.new.perform("3kabc", url, "Hi", %w[bluesky mastodon]) }
        .to raise_error(/bluesky: Bluesky refused the post/)

      expect(mastodon).to have_received(:post!).once
    end

    it "raises, thus Sidekiq does the job again" do
      expect { described_class.new.perform("3kabc", url, "Hi", [ "bluesky" ]) }
        .to raise_error(/SharePostJob: bluesky:/)
    end
  end

  # The 24-hour retry of ApplicationJob only stays safe because the key comes from the caller:
  # Bluesky writes with putRecord at that key, and Mastodon reads it as its Idempotency-Key.
  it "gives the same key to each attempt of both networks" do
    2.times { described_class.new.perform("3kabc", url, "Hi", %w[bluesky mastodon]) }

    expect(bluesky).to have_received(:post!).twice.with(hash_including(rkey: "3kabc"))
    expect(mastodon).to have_received(:post!).twice.with(hash_including(idempotency_key: "3kabc"))
  end
end
