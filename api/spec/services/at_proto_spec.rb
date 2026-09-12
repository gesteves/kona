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

    it "gives nil for a key whose high bit is not zero" do
      # ⚠️ `StandardSite.tid` makes a key from a digest, thus its high bit is not always zero and
      # the time that such a key holds means nothing. A Time that means nothing is worse than nil:
      # `Bluesky#post!` would write it into createdAt.
      high_bit_set = "z" + ("2" * 12)

      expect(Bluesky.tid_time(high_bit_set)).to be_nil
      expect(Bluesky.tid_time(Bluesky.new_tid)).to be_a(Time)
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
