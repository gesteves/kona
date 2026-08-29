require "rails_helper"

RSpec.describe MastodonPostJob do
  let(:mastodon) { instance_double(Mastodon) }
  let(:open_graph) { instance_double(OpenGraph) }
  let(:url) { "https://example.test/a-post/" }

  before do
    allow(Mastodon).to receive(:new).and_return(mastodon)
    allow(mastodon).to receive(:post!).and_return("https://instance.test/@me/1")
    allow(OpenGraph).to receive(:new).and_return(open_graph)
    allow(open_graph).to receive(:fetch)
  end

  # ⚠️ Mastodon renders the link inline and makes its own preview card. Thus the URL goes to it as
  # a plain argument, and this job reads no og: tags.
  it "posts the link with the body, and reads no og: tags" do
    described_class.new.perform("3kabc", url, "Read this")

    expect(mastodon).to have_received(:post!)
      .with(text: "Read this", url: url, idempotency_key: "3kabc")
    expect(open_graph).not_to have_received(:fetch)
  end

  # ⚠️ The instance answers with the status that it made already while that key is the same.
  it "gives the same idempotency key to each attempt" do
    2.times { described_class.new.perform("3kabc", url, "Hi") }

    expect(mastodon).to have_received(:post!).twice.with(hash_including(idempotency_key: "3kabc"))
  end

  it "raises, thus Sidekiq does the job again" do
    allow(mastodon).to receive(:post!).and_raise("the instance refused")

    expect { described_class.new.perform("3kabc", url, "Hi") }.to raise_error(/refused/)
  end
end
