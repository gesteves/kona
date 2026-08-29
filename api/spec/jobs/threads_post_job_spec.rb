require "rails_helper"

RSpec.describe ThreadsPostJob do
  let(:threads) { instance_double(Threads) }
  let(:open_graph) { instance_double(OpenGraph) }
  let(:url) { "https://example.test/a-post/" }

  def post(key, text, link = "")
    { "key" => key, "text" => text, "link" => link }
  end

  before do
    described_class.jobs.clear
    allow(Threads).to receive(:new).and_return(threads)
    allow(threads).to receive(:post!).and_return("17900000000000000")
    allow(OpenGraph).to receive(:new).and_return(open_graph)
    allow(open_graph).to receive(:fetch)
  end

  # ⚠️ Threads attaches the link itself, thus this job reads no og: tags either.
  it "posts the link with the body, and reads no og: tags" do
    described_class.new.perform([ post("3kabc", "Read this", url) ])

    expect(threads).to have_received(:post!)
      .with(text: "Read this", url: url, idempotency_key: "3kabc", reply_to_id: nil)
    expect(open_graph).not_to have_received(:fetch)
  end

  it "posts with no link at all" do
    described_class.new.perform([ post("3kabc", "No link here") ])

    expect(threads).to have_received(:post!).with(hash_including(url: ""))
  end

  # ⚠️ Meta gives no idempotency header. Threads#post! keeps the media container below this key,
  # thus a retry publishes the container that it made already.
  it "gives the same key to each attempt" do
    2.times { described_class.new.perform([ post("3kabc", "Hi") ]) }

    expect(threads).to have_received(:post!).twice.with(hash_including(idempotency_key: "3kabc"))
  end

  it "raises, thus Sidekiq does the job again" do
    allow(threads).to receive(:post!).and_raise("Threads refused to publish")

    expect { described_class.new.perform([ post("3kabc", "Hi") ]) }.to raise_error(/refused/)
  end

  describe "a thread" do
    let(:thread) { [ post("k1", "One"), post("k2", "Two") ] }

    # ⚠️ The reply goes on the CONTAINER, and the media id of the post above is what names it.
    it "names the post above it and adds the job of the next post" do
      described_class.new.perform(thread)

      expect(threads).to have_received(:post!).with(hash_including(reply_to_id: nil))
      posts, index, reply_to_id = described_class.jobs.first["args"]
      expect(posts.length).to eq(2)
      expect(index).to eq(1)
      expect(reply_to_id).to eq("17900000000000000")
    end

    it "adds no job after the last post" do
      described_class.new.perform(thread, 1, "17900000000000000")

      expect(threads).to have_received(:post!)
        .with(hash_including(idempotency_key: "k2", reply_to_id: "17900000000000000"))
      expect(described_class.jobs).to be_empty
    end
  end
end
