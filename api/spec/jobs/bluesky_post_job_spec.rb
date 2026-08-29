require "rails_helper"

RSpec.describe BlueskyPostJob do
  let(:bluesky) { instance_double(Bluesky) }
  let(:open_graph) { instance_double(OpenGraph) }
  let(:url) { "https://example.test/a-post/" }
  let(:card) do
    OpenGraph::Card.new(url: url, title: "A title", description: "A summary.",
                        image_url: "https://cdn.test/og.png")
  end

  before do
    allow(Bluesky).to receive(:new).and_return(bluesky)
    allow(bluesky).to receive(:post!).and_return("https://bsky.app/profile/me/post/3kabc")
    allow(OpenGraph).to receive(:new).and_return(open_graph)
    allow(open_graph).to receive(:fetch).and_return(card)
  end

  # ⚠️ The card comes from the og: tags of the page. A Short has no cover image, and the link can
  # be a page on another site.
  it "posts with the card of the linked page" do
    described_class.new.perform("3kabc", url, "Read this")

    expect(open_graph).to have_received(:fetch).with(url)
    expect(bluesky).to have_received(:post!).with(rkey: "3kabc", text: "Read this", card: card)
  end

  # The 24-hour retry only stays safe because the key comes from the caller: Bluesky writes with
  # putRecord at that key.
  it "gives the same record key to each attempt" do
    2.times { described_class.new.perform("3kabc", url, "Hi") }

    expect(bluesky).to have_received(:post!).twice.with(hash_including(rkey: "3kabc"))
  end

  it "raises, thus Sidekiq does the job again" do
    allow(bluesky).to receive(:post!).and_raise("Bluesky refused the post")

    expect { described_class.new.perform("3kabc", url, "Hi") }.to raise_error(/refused/)
  end
end
