require "rails_helper"

# `AtProto` had no spec of its own: each of its methods ran only through `Bluesky`. The session
# cache, the retry after a refusal, and the lock of `new_tid` are the parts that a Bluesky example
# cannot reach.
RSpec.describe AtProto do
  subject(:service) { Bluesky.new(credentials: credentials) }

  let(:credentials) { BlueskyCredentials::Credentials.new(handle: "me.bsky.social", app_password: "pw") }
  let(:session_body) do
    { accessJwt: "jwt", did: "did:plc:abc",
      didDoc: { service: [ { id: "#atproto_pds", serviceEndpoint: "https://pds.test" } ] } }.to_json
  end

  def open_session
    service.send(:open_session, handle: "me.bsky.social", app_password: "pw")
  end

  describe "the TID" do
    it "always rises, so the posts of a thread sort in the order that a person wrote them" do
      # ⚠️ The 10 low bits are random and a caller makes several keys inside one microsecond, thus
      # without the lock and the monotonic bump a reply sorts above its own root.
      tids = Array.new(1000) { Bluesky.new_tid }

      expect(tids).to eq(tids.sort)
      expect(tids.uniq.length).to eq(tids.length)
    end

    it "rises across threads" do
      tids = 4.times.map { Thread.new { Array.new(250) { Bluesky.new_tid } } }.flat_map(&:value)

      expect(tids.uniq.length).to eq(tids.length)
    end

    it "gives nil for 13 characters that are not a TID" do
      high_bit_set = "z" + ("2" * 12)

      expect(Bluesky.tid_time(high_bit_set)).to be_nil
      expect(Bluesky.tid_time(Bluesky.new_tid)).to be_a(Time)
    end

    # ⚠️ This is what the check above CANNOT do, and the comment there used to claim it could.
    # `StandardSite.tid` keeps the low 63 bits of a digest, thus its high bit is zero and it looks
    # exactly like a time-ordered key. Nothing can tell the two apart by reading them.
    it "cannot tell a content-addressed key from a time-ordered one" do
      expect(Bluesky.tid_time(StandardSite.tid("an entry"))).to be_a(Time)
    end
  end

  describe "the session" do
    before do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.server.createSession"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, body: session_body))
    end

    it "keeps the session, so a thread does not open one for each post" do
      # ⚠️ createSession permits 30 calls each 5 minutes for each account, thus a thread of 25
      # posts used most of that window before its first retry.
      expect(open_session).to be true
      expect(Bluesky.new(credentials: credentials).send(:open_session, handle: "me.bsky.social", app_password: "pw")).to be true

      expect(HTTParty).to have_received(:post)
        .with(a_string_including("com.atproto.server.createSession"), anything).once
    end

    it "reads the service endpoint of the repo out of the DID document" do
      open_session

      expect(service.instance_variable_get(:@service_url)).to eq("https://pds.test")
    end

    it "gives false and keeps no session when the PDS refuses the credentials" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.server.createSession"), anything)
        .and_return(instance_double(HTTParty::Response, success?: false, code: 401, body: "no"))

      expect(open_session).to be false
      expect($redis.get("#{described_class::SESSION_KEY_PREFIX}me.bsky.social")).to be_nil
    end
  end

  # ⚠️ These two were private to `StandardSite`, where they used `auth_headers` with no timeout, no
  # retry after a refused token, and no rescue. The session cache made the second one necessary: the
  # token now comes from Redis and a person can revoke it inside its 55 minutes.
  # ⚠️ The Images API takes a size in PIXELS and promises nothing in BYTES. A cover image with much
  # detail came back above the blob limit, the PDS refused the record, and the job then tried again
  # for 24 hours for a reason that cannot change.
  describe "#upload_image_blob" do
    let(:limit) { StandardSite::MAX_BLOB_BYTES }

    before do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.server.createSession"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, body: session_body))
      open_session
      allow(service).to receive(:download).and_return({ body: oversized, content_type: "image/jpeg" })
    end

    let(:oversized) { "x" * (StandardSite::MAX_BLOB_BYTES + 1) }

    def upload
      service.send(:upload_image_blob, "https://images.ctfassets.net/a/b/c.jpg", "image/jpeg",
                   w: 1200, h: 630, limit: limit)
    end

    it "shrinks a picture that is above the limit, rather than losing it" do
      small = "j" * (limit - 1)
      allow(service).to receive(:shrink_image).with(oversized, limit: limit).and_return([ small, "image/jpeg" ])
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.uploadBlob"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, code: 200,
                                    body: { blob: { "$type" => "blob" } }.to_json))

      expect(upload).to eq({ "$type" => "blob" })
      expect(service).to have_received(:shrink_image)
    end

    it "drops the picture, and not the record, when no step of the shrink fits" do
      allow(service).to receive(:shrink_image).and_return([ oversized, "image/jpeg" ])

      expect(upload).to be_nil
    end

    # ⚠️ The worker is a 512MB VM at concurrency 5, and the size of that body belongs to another host.
    it "caps the download" do
      allow(service).to receive(:shrink_image).and_return([ "small", "image/jpeg" ])
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.uploadBlob"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, code: 200, body: { blob: {} }.to_json))

      upload

      expect(service).to have_received(:download)
        .with(anything, hash_including(max_bytes: described_class::MAX_SOURCE_IMAGE_BYTES))
    end
  end

  # ⚠️ A 429 went through `unless response.success?`, which answers nil. `StandardSite` then wrote
  # "putRecord failed" to the log and the JOB ENDED WITH NO ERROR, thus Sidekiq did it no more times
  # and the record never reached the PDS. A limit that lifts by itself lost a record for ever.
  describe "a 429 from the PDS" do
    before do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.server.createSession"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, body: session_body))
      open_session
    end

    def limited(headers)
      instance_double(HTTParty::Response, success?: false, code: 429, body: "slow down", headers: headers)
    end

    it "raises with the time that the PDS gave" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.putRecord"), anything)
        .and_return(limited("ratelimit-reset" => 5.minutes.from_now.to_i.to_s))

      expect { service.send(:put_record, "site.standard.document", "3kabc", {}) }
        .to raise_error(AtProto::RateLimitedError) { |e| expect(e.retry_after).to be_within(5).of(300) }
    end

    it "waits a time that makes sense when the header is absent" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.putRecord"), anything)
        .and_return(limited({}))

      expect { service.send(:put_record, "site.standard.document", "3kabc", {}) }
        .to raise_error(AtProto::RateLimitedError) { |e| expect(e.retry_after).to eq(60) }
    end

    it "raises from a delete also, and does not report it as a delete that failed" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.deleteRecord"), anything)
        .and_return(limited({}))

      expect { service.send(:delete_record, "site.standard.document", "3kabc") }
        .to raise_error(AtProto::RateLimitedError)
    end

    it "raises from a blob upload also" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.uploadBlob"), anything)
        .and_return(limited({}))

      expect { service.send(:upload_blob, "bytes", "image/jpeg") }
        .to raise_error(AtProto::RateLimitedError)
    end

    it "makes a job wait that long in place of using its budget" do
      limit = AtProto::RateLimitedError.new("slow down", retry_after: 420)

      expect(ApplicationJob.sidekiq_retry_in_block.call(1, limit, {})).to eq(420)
    end
  end

  describe "#delete_record" do
    before do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.server.createSession"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, body: session_body))
      open_session
    end

    def delete = service.send(:delete_record, "site.standard.document", "3kabc")

    it "opens a new session and deletes one time more when the PDS refuses the token" do
      responses = [
        instance_double(HTTParty::Response, success?: false, code: 401, body: "expired"),
        instance_double(HTTParty::Response, success?: true, code: 200, body: "{}")
      ]
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.deleteRecord"), anything) { responses.shift }

      expect(delete).to be(true)
      expect(HTTParty).to have_received(:post)
        .with(a_string_including("com.atproto.server.createSession"), anything).twice
    end

    it "gives false when the second attempt is also refused" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.deleteRecord"), anything)
        .and_return(instance_double(HTTParty::Response, success?: false, code: 401, body: "expired"))

      expect(delete).to be(false)
    end

    # ⚠️ The prune of a backfill calls this for each record that is no longer current. A raise there
    # would stop a full reconciliation because of one record, which is what the comment on
    # `StandardSite#remove_document!` says must not happen.
    it "gives false and does not raise when the host cannot be reached" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.deleteRecord"), anything)
        .and_raise(SocketError.new("getaddrinfo"))

      expect(delete).to be(false)
    end

    it "sends a timeout, so a host that hangs cannot hold a worker thread" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.deleteRecord"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, code: 200, body: "{}"))

      delete

      expect(HTTParty).to have_received(:post)
        .with(a_string_including("com.atproto.repo.deleteRecord"),
              hash_including(timeout: described_class::REQUEST_TIMEOUT))
    end
  end

  describe "#put_record" do
    before do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.server.createSession"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, body: session_body))
      open_session
    end

    def put
      service.send(:put_record, "app.bsky.feed.post", "3kabc", { "text" => "hi" })
    end

    it "gives the reference of the record that it wrote" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.putRecord"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, code: 200,
                                    body: { uri: "at://did:plc:abc/app.bsky.feed.post/3kabc", cid: "bafy" }.to_json))

      expect(put).to eq({ "uri" => "at://did:plc:abc/app.bsky.feed.post/3kabc", "cid" => "bafy" })
    end

    it "gives nil for a write that comes back with no cid" do
      # ⚠️ A reply names its parent by uri AND cid, thus a reference with no cid fails the next post
      # of the thread, with a message that names that post.
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.putRecord"), anything)
        .and_return(instance_double(HTTParty::Response, success?: true, code: 200,
                                    body: { uri: "at://did:plc:abc/app.bsky.feed.post/3kabc" }.to_json))

      expect(put).to be_nil
    end

    it "opens a new session and writes one time more when the PDS refuses the token" do
      # ⚠️ A token can stop working before its key expires: a person revokes it, or changes the app
      # password. Without this, each write for the rest of the TTL fails against the same token.
      written = { uri: "at://did:plc:abc/app.bsky.feed.post/3kabc", cid: "bafy" }.to_json
      responses = [
        instance_double(HTTParty::Response, success?: false, code: 401, body: "expired"),
        instance_double(HTTParty::Response, success?: true, code: 200, body: written)
      ]
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.putRecord"), anything) { responses.shift }

      expect(put).to eq({ "uri" => "at://did:plc:abc/app.bsky.feed.post/3kabc", "cid" => "bafy" })
      expect(HTTParty).to have_received(:post)
        .with(a_string_including("com.atproto.server.createSession"), anything).twice
    end

    it "gives nil when the second attempt is also refused" do
      allow(HTTParty).to receive(:post)
        .with(a_string_including("com.atproto.repo.putRecord"), anything)
        .and_return(instance_double(HTTParty::Response, success?: false, code: 401, body: "expired"))

      expect(put).to be_nil
    end
  end

  describe "#truncate_graphemes" do
    it "counts graphemes and not code units" do
      expect(service.send(:truncate_graphemes, "🎉🎉🎉", 2)).to eq("🎉🎉")
    end

    it "leaves a string that already fits" do
      expect(service.send(:truncate_graphemes, "hello", 10)).to eq("hello")
    end
  end
end
