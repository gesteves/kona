require "rails_helper"

RSpec.describe BlueskyPostJob do
  let(:bluesky) { instance_double(Bluesky) }
  let(:open_graph) { instance_double(OpenGraph) }
  let(:url) { "https://example.test/a-post/" }
  let(:card) do
    OpenGraph::Card.new(url: url, title: "A title", description: "A summary.",
                        image_url: "https://cdn.test/og.png")
  end

  # One post of the thread, as the controller builds it.
  def post(key, text, link = "")
    { "key" => key, "text" => text, "link" => link }
  end

  def written(uri, cid)
    { "uri" => uri, "cid" => cid, "url" => "https://bsky.app/profile/me/post/#{cid}" }
  end

  before do
    described_class.jobs.clear
    allow(Bluesky).to receive(:new).and_return(bluesky)
    allow(bluesky).to receive(:post!).and_return(written("at://did/app.bsky.feed.post/1", "cid1"))
    allow(OpenGraph).to receive(:new).and_return(open_graph)
    allow(open_graph).to receive(:fetch).and_return(card)
  end

  # ⚠️ The card comes from the og: tags of the page. A Short has no cover image, and the link can
  # be a page on another site.
  it "posts with the card of the linked page" do
    described_class.new.perform([ post("3kabc", "Read this", url) ])

    expect(open_graph).to have_received(:fetch).with(url)
    expect(bluesky).to have_received(:post!)
      .with(rkey: "3kabc", text: "Read this", card: card, reply: nil, photos: [])
  end

  # ⚠️ The link is optional. A post with none must read no page at all.
  it "reads no page and sends no card when there is no link" do
    described_class.new.perform([ post("3kabc", "No link here") ])

    expect(open_graph).not_to have_received(:fetch)
    expect(bluesky).to have_received(:post!).with(hash_including(card: nil))
  end

  # ⚠️ An embed from a page with no og: tags is an empty box with a host name in it. Thus the link
  # goes in the words, as it does at Mastodon.
  it "puts the link in the text and sends no card when the page gives no tags" do
    allow(open_graph).to receive(:fetch)
      .and_return(OpenGraph::Card.new(url: url, title: nil, description: nil, image_url: nil))

    described_class.new.perform([ post("3kabc", "Read this", url) ])

    expect(bluesky).to have_received(:post!)
      .with(rkey: "3kabc", text: "Read this\n\n#{url}", card: nil, reply: nil, photos: [])
  end

  # ⚠️ A scheduled post runs days after the check on the page. A page that lost its og: tags puts
  # the link in the words, and a long post then passes 300.
  it "drops the link, and does not fail, when the page lost its card and the words no longer fit" do
    allow(open_graph).to receive(:fetch)
      .and_return(OpenGraph::Card.new(url: url, title: nil, description: nil, image_url: nil))
    words = "a" * 290

    described_class.new.perform([ post("3kabc", words, url) ])

    expect(bluesky).to have_received(:post!).with(rkey: "3kabc", text: words, card: nil, reply: nil, photos: [])
  end

  # A page that gives one of the three fields still draws a card, thus its link stays out of the
  # words and uses none of the 300 characters.
  it "keeps the link out of the text when the page gives a title alone" do
    allow(open_graph).to receive(:fetch)
      .and_return(OpenGraph::Card.new(url: url, title: "A title", description: nil, image_url: nil))

    described_class.new.perform([ post("3kabc", "Read this", url) ])

    expect(bluesky).to have_received(:post!).with(hash_including(text: "Read this"))
  end

  # The 24-hour retry only stays safe because the key comes from the caller: Bluesky writes with
  # putRecord at that key.
  it "gives the same record key to each attempt" do
    2.times { described_class.new.perform([ post("3kabc", "Hi") ]) }

    expect(bluesky).to have_received(:post!).twice.with(hash_including(rkey: "3kabc"))
  end

  it "raises, thus Sidekiq does the job again" do
    allow(bluesky).to receive(:post!).and_raise("Bluesky refused the post")

    expect { described_class.new.perform([ post("3kabc", "Hi") ]) }.to raise_error(/refused/)
  end

  describe "the photos" do
    let(:store) { SocialPhotos.new }
    let(:jpeg) { "\xFF\xD8\xFF\xE0jpeg".b }
    let!(:first) { store.store(image: jpeg, width: 4, height: 3) }
    let!(:second) { store.store(image: jpeg, width: 3, height: 4) }
    let(:with_photos) do
      post("3kabc", "Two photos").merge("photos" => [ { "id" => first, "alt" => "A cat" },
                                                       { "id" => second, "alt" => "" } ])
    end

    after { store.discard([ first, second ]) }

    it "reads each photo from the store and gives it to the post, in order, with its alt text" do
      described_class.new.perform([ with_photos ])

      expect(bluesky).to have_received(:post!).with(
        rkey: "3kabc", text: "Two photos", card: nil, reply: nil,
        photos: [ { bytes: jpeg, width: 4, height: 3, alt: "A cat" },
                  { bytes: jpeg, width: 3, height: 4, alt: "" } ]
      )
    end

    # ⚠️ Bluesky renders ONE embed, and the photos are it. A hand-written payload with a link as
    # well must not read the page.
    it "reads no page for a post with photos, even with a link" do
      described_class.new.perform([ with_photos.merge("link" => url) ])

      expect(open_graph).not_to have_received(:fetch)
      expect(bluesky).to have_received(:post!).with(hash_including(card: nil, text: "Two photos"))
    end

    # ⚠️ Mastodon reads the same photos in its own job, in no known order. The TTL removes them.
    it "keeps the photos after the write" do
      described_class.new.perform([ with_photos ])

      expect(store.exists?(first)).to be(true)
      expect(store.exists?(second)).to be(true)
    end

    # ⚠️ A post that promised photos must not go out as words alone, and no retry can bring a
    # photo back.
    it "fails the post for good when a photo is gone, and posts nothing" do
      store.discard([ second ])

      expect { described_class.new.perform([ with_photos ]) }
        .to raise_error(ApplicationJob::PermanentError, /lost its photo #{second}/)
      expect(bluesky).not_to have_received(:post!)
    end

    it "keeps the photos when the write fails, thus the retry finds them" do
      allow(bluesky).to receive(:post!).and_raise("Bluesky refused the post")

      expect { described_class.new.perform([ with_photos ]) }.to raise_error(/refused/)
      expect(store.exists?(first)).to be(true)
    end
  end

  describe "a thread" do
    let(:thread) { [ post("k1", "One"), post("k2", "Two"), post("k3", "Three") ] }

    # ⚠️ One job for each POST. Thus a failure runs one post again and never a post that already
    # went out.
    it "posts the first and adds the job of the second" do
      described_class.new.perform(thread)

      expect(bluesky).to have_received(:post!).once.with(hash_including(rkey: "k1", reply: nil))
      expect(described_class.jobs.size).to eq(1)
      posts, index, reply = described_class.jobs.first["args"]
      expect(posts.length).to eq(3)
      expect(index).to eq(1)
      expect(reply).to eq({
        "root" => { "uri" => "at://did/app.bsky.feed.post/1", "cid" => "cid1" },
        "parent" => { "uri" => "at://did/app.bsky.feed.post/1", "cid" => "cid1" }
      })
    end

    # ⚠️ The root of a thread is the FIRST post, and the parent is the one just above.
    it "keeps the root of the thread and moves the parent" do
      allow(bluesky).to receive(:post!).and_return(written("at://did/app.bsky.feed.post/2", "cid2"))
      root = { "uri" => "at://did/app.bsky.feed.post/1", "cid" => "cid1" }

      described_class.new.perform(thread, 1, { "root" => root, "parent" => root })

      expect(bluesky).to have_received(:post!).with(hash_including(rkey: "k2"))
      _posts, index, reply = described_class.jobs.first["args"]
      expect(index).to eq(2)
      expect(reply["root"]).to eq(root)
      expect(reply["parent"]).to eq({ "uri" => "at://did/app.bsky.feed.post/2", "cid" => "cid2" })
    end

    # ⚠️ The enqueue of the next post is INSIDE the job of the post above it. When the process dies
    # after that enqueue and before Sidekiq acknowledges the job, the retry does this post again —
    # which is safe, the rkey is the same — and it would add the next job a second time. The tail
    # of the thread then goes out two times.
    it "adds the job of the next post one time only, however many times this job runs" do
      described_class.new.perform(thread)
      described_class.new.perform(thread)

      expect(described_class.jobs.size).to eq(1)
    end

    it "adds no job after the last post" do
      described_class.new.perform(thread, 2, { "root" => {}, "parent" => {} })

      expect(bluesky).to have_received(:post!).with(hash_including(rkey: "k3"))
      expect(described_class.jobs).to be_empty
    end

    # An index past the end is a job that ran already, thus it must do nothing and not raise.
    it "does nothing for an index that is not there" do
      described_class.new.perform(thread, 9)

      expect(bluesky).not_to have_received(:post!)
    end
  end
end
