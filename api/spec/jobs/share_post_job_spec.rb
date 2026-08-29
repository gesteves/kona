require "rails_helper"

RSpec.describe SharePostJob do
  let(:bluesky) { instance_double(Bluesky) }
  let(:open_graph) { instance_double(OpenGraph) }
  let(:url) { "https://example.test/2026/07/12/ic/" }
  let(:card) do
    OpenGraph::Card.new(url: url, title: "Ironman Canada", description: "A long day.",
                        image_url: "https://cdn.test/og.png")
  end

  before do
    allow(Bluesky).to receive(:new).and_return(bluesky)
    allow(bluesky).to receive(:post!).and_return("https://bsky.app/profile/me/post/3kabc")
    allow(OpenGraph).to receive(:new).and_return(open_graph)
    allow(open_graph).to receive(:fetch).and_return(card)
  end

  # ⚠️ The card comes from the og: tags of the page, and not from Contentful. A Short has no cover
  # image, and the link can also be a page on another site.
  it "posts the body with the card of the linked page" do
    described_class.new.perform("3kabc", url, "Read this", [ "bluesky" ])

    expect(open_graph).to have_received(:fetch).with(url)
    expect(bluesky).to have_received(:post!).with(rkey: "3kabc", text: "Read this", card: card)
  end

  it "shares a link to another site" do
    other = "https://someone-else.test/a-post/"
    described_class.new.perform("3kabc", other, "Good read", [ "bluesky" ])

    expect(open_graph).to have_received(:fetch).with(other)
  end

  # ⚠️ Only Bluesky posts today. A key that no code sends to is a skip and never an error, thus a
  # draft that names one does not go into the Dead set.
  it "skips a network that is not wired up yet" do
    described_class.new.perform("3kabc", url, "Hi", %w[bluesky mastodon threads])

    expect(bluesky).to have_received(:post!).once
  end

  it "does nothing when no network is wired up yet" do
    described_class.new.perform("3kabc", url, "Hi", %w[mastodon threads])

    expect(bluesky).not_to have_received(:post!)
    expect(open_graph).not_to have_received(:fetch)
  end

  # The 24-hour retry of ApplicationJob only stays safe because the key comes from the caller and
  # Bluesky#post! writes with putRecord.
  it "gives the record key that the caller made to each attempt" do
    2.times { described_class.new.perform("3kabc", url, "Hi", [ "bluesky" ]) }

    expect(bluesky).to have_received(:post!).twice.with(hash_including(rkey: "3kabc"))
  end
end
