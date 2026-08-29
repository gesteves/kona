require "rails_helper"

RSpec.describe MastodonPostJob do
  let(:mastodon) { instance_double(Mastodon) }
  let(:open_graph) { instance_double(OpenGraph) }
  let(:url) { "https://example.test/a-post/" }

  def post(key, text, link = "")
    { "key" => key, "text" => text, "link" => link }
  end

  before do
    described_class.jobs.clear
    allow(Mastodon).to receive(:new).and_return(mastodon)
    allow(mastodon).to receive(:post!)
      .and_return({ "id" => "101", "url" => "https://instance.test/@me/101" })
    allow(OpenGraph).to receive(:new).and_return(open_graph)
    allow(open_graph).to receive(:fetch)
  end

  # ⚠️ Mastodon renders the link inline and makes its own preview card. Thus the URL goes to it as
  # a plain argument, and this job reads no og: tags.
  it "posts the link with the body, and reads no og: tags" do
    described_class.new.perform([ post("3kabc", "Read this", url) ])

    expect(mastodon).to have_received(:post!)
      .with(text: "Read this", url: url, idempotency_key: "3kabc", in_reply_to_id: nil)
    expect(open_graph).not_to have_received(:fetch)
  end

  it "posts with no link at all" do
    described_class.new.perform([ post("3kabc", "No link here") ])

    expect(mastodon).to have_received(:post!).with(hash_including(url: ""))
  end

  # ⚠️ The instance answers with the status that it made already while that key is the same.
  it "gives the same idempotency key to each attempt" do
    2.times { described_class.new.perform([ post("3kabc", "Hi") ]) }

    expect(mastodon).to have_received(:post!).twice.with(hash_including(idempotency_key: "3kabc"))
  end

  it "raises, thus Sidekiq does the job again" do
    allow(mastodon).to receive(:post!).and_raise("the instance refused")

    expect { described_class.new.perform([ post("3kabc", "Hi") ]) }.to raise_error(/refused/)
  end

  describe "a thread" do
    let(:thread) { [ post("k1", "One"), post("k2", "Two") ] }

    it "names the status above it and adds the job of the next post" do
      described_class.new.perform(thread)

      expect(mastodon).to have_received(:post!).with(hash_including(in_reply_to_id: nil))
      posts, index, in_reply_to_id = described_class.jobs.first["args"]
      expect(posts.length).to eq(2)
      expect(index).to eq(1)
      expect(in_reply_to_id).to eq("101")
    end

    it "adds no job after the last post" do
      described_class.new.perform(thread, 1, "101")

      expect(mastodon).to have_received(:post!)
        .with(hash_including(idempotency_key: "k2", in_reply_to_id: "101"))
      expect(described_class.jobs).to be_empty
    end
  end
end
