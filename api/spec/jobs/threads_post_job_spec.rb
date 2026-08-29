require "rails_helper"

RSpec.describe ThreadsPostJob do
  let(:threads) { instance_double(Threads) }
  let(:open_graph) { instance_double(OpenGraph) }
  let(:url) { "https://example.test/a-post/" }

  before do
    allow(Threads).to receive(:new).and_return(threads)
    allow(threads).to receive(:post!).and_return("17900000000000000")
    allow(OpenGraph).to receive(:new).and_return(open_graph)
    allow(open_graph).to receive(:fetch)
  end

  # ⚠️ Threads attaches the link itself, thus this job reads no og: tags either.
  it "posts the link with the body, and reads no og: tags" do
    described_class.new.perform("3kabc", url, "Read this")

    expect(threads).to have_received(:post!)
      .with(text: "Read this", url: url, idempotency_key: "3kabc")
    expect(open_graph).not_to have_received(:fetch)
  end

  # ⚠️ Meta gives no idempotency header. Threads#post! keeps the media container below this key,
  # thus a retry publishes the container that it made already.
  it "gives the same key to each attempt" do
    2.times { described_class.new.perform("3kabc", url, "Hi") }

    expect(threads).to have_received(:post!).twice.with(hash_including(idempotency_key: "3kabc"))
  end

  it "raises, thus Sidekiq does the job again" do
    allow(threads).to receive(:post!).and_raise("Threads refused to publish")

    expect { described_class.new.perform("3kabc", url, "Hi") }.to raise_error(/refused/)
  end
end
