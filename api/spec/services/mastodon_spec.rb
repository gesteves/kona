require "rails_helper"

RSpec.describe Mastodon do
  let(:redirect_uri) { "https://admin.example.test/connected-apps/mastodon/callback" }

  before { $redis.del(MastodonCredentials::REDIS_KEY) }

  after { $redis.del(MastodonCredentials::REDIS_KEY) }

  def http_response(body, success: true, code: 200)
    instance_double(HTTParty::Response, success?: success, code: code, body: body.to_json, request: nil)
  end

  def register_client!
    MastodonCredentials.store_client(
      instance: "mastodon.social", client_id: "client-id", client_secret: "client-secret",
      redirect_uri: redirect_uri
    )
  end

  def connect_account!
    register_client!
    MastodonCredentials.store_token(access_token: "an-access-token", handle: "@me@mastodon.social")
  end

  describe ".normalize_instance" do
    it "accepts a bare hostname" do
      expect(described_class.normalize_instance("mastodon.social")).to eq("mastodon.social")
    end

    it "takes the host out of a URL, and lowercases it" do
      expect(described_class.normalize_instance(" https://Mastodon.Social/about ")).to eq("mastodon.social")
    end

    it "takes the instance out of a full handle" do
      expect(described_class.normalize_instance("@me@mastodon.social")).to eq("mastodon.social")
    end

    it "refuses a value that cannot be a hostname" do
      [ "", nil, "not a host", "localhost", "mastodon .social" ].each do |value|
        expect(described_class.normalize_instance(value)).to be_nil
      end
    end
  end

  describe "#register!" do
    it "stores the client that the instance gives" do
      allow(HTTParty).to receive(:post)
        .and_return(http_response({ client_id: "abc", client_secret: "xyz" }))

      expect(described_class.new.register!(instance: "mastodon.social", redirect_uri: redirect_uri)).to be(true)

      credentials = MastodonCredentials.fetch
      expect(credentials.instance).to eq("mastodon.social")
      expect(credentials.client_id).to eq("abc")
      expect(credentials.client_secret).to eq("xyz")
      expect(credentials.redirect_uri).to eq(redirect_uri)
    end

    # ⚠️ The owner types the hostname, and the form is a request with a 20-second rack-timeout. A
    # host that accepts the connection and then hangs must give the message of the form.
    it "asks the named instance for a client, with the callback of this app and a timeout" do
      allow(HTTParty).to receive(:post).and_return(http_response({ client_id: "abc", client_secret: "xyz" }))

      described_class.new.register!(instance: "mastodon.social", redirect_uri: redirect_uri)

      expect(HTTParty).to have_received(:post).with(
        "https://mastodon.social/api/v1/apps",
        hash_including(body: hash_including(redirect_uris: redirect_uri, scopes: described_class::SCOPES),
                       timeout: described_class::REQUEST_TIMEOUT)
      )
    end

    it "stores nothing when the instance refuses" do
      allow(HTTParty).to receive(:post).and_return(http_response({ error: "nope" }, success: false, code: 422))

      expect(described_class.new.register!(instance: "mastodon.social", redirect_uri: redirect_uri)).to be(false)
      expect(MastodonCredentials.fetch).not_to be_registered
    end

    # A hostname with a typing error is the common failure here, and it is a connection error and
    # not a status.
    it "stores nothing when the instance cannot be reached" do
      allow(HTTParty).to receive(:post).and_raise(SocketError)

      expect(described_class.new.register!(instance: "no.such.host", redirect_uri: redirect_uri)).to be(false)
      expect(MastodonCredentials.fetch).not_to be_registered
    end
  end

  describe "#authorization_url" do
    it "points at the instance and carries the state" do
      register_client!

      url = described_class.new.authorization_url("a-state")

      expect(url).to start_with("https://mastodon.social/oauth/authorize?")
      expect(url).to include("client_id=client-id")
      expect(url).to include("response_type=code")
      expect(url).to include("state=a-state")
      expect(url).to include(CGI.escape(redirect_uri))
    end

    it "is nil with no registration" do
      expect(described_class.new.authorization_url("a-state")).to be_nil
    end
  end

  describe "#connect!" do
    before { register_client! }

    it "stores the token and the handle of the account" do
      allow(HTTParty).to receive(:post).and_return(http_response({ access_token: "an-access-token" }))
      allow(HTTParty).to receive(:get).and_return(http_response({ acct: "me" }))

      expect(described_class.new.connect!("a-code")).to be(true)

      credentials = MastodonCredentials.fetch
      expect(credentials.access_token).to eq("an-access-token")
      expect(credentials.handle).to eq("@me@mastodon.social")
    end

    it "exchanges the code with the same redirect URI that the registration named" do
      allow(HTTParty).to receive(:post).and_return(http_response({ access_token: "an-access-token" }))
      allow(HTTParty).to receive(:get).and_return(http_response({ acct: "me" }))

      described_class.new.connect!("a-code")

      expect(HTTParty).to have_received(:post).with(
        "https://mastodon.social/oauth/token",
        hash_including(body: hash_including(code: "a-code", redirect_uri: redirect_uri, grant_type: "authorization_code"))
      )
    end

    it "stores nothing when the instance gives no token" do
      allow(HTTParty).to receive(:post).and_return(http_response({ error: "invalid_grant" }, success: false, code: 400))

      expect(described_class.new.connect!("a-code")).to be(false)
      expect(MastodonCredentials.connected?).to be(false)
    end

    # ⚠️ A token that cannot read its own account is not a connection, and the page must not show
    # one.
    it "stores nothing when the token cannot read the account" do
      allow(HTTParty).to receive(:post).and_return(http_response({ access_token: "an-access-token" }))
      allow(HTTParty).to receive(:get).and_return(http_response({ error: "unauthorized" }, success: false, code: 401))

      expect(described_class.new.connect!("a-code")).to be(false)
      expect(MastodonCredentials.connected?).to be(false)
    end

    it "does nothing with no registration" do
      MastodonCredentials.clear
      allow(HTTParty).to receive(:post)

      expect(described_class.new.connect!("a-code")).to be(false)
      expect(HTTParty).not_to have_received(:post)
    end
  end

  describe "#disconnect!" do
    before do
      register_client!
      MastodonCredentials.store_token(access_token: "an-access-token", handle: "@me@mastodon.social")
    end

    it "tells the instance to forget the token, then clears the store" do
      allow(HTTParty).to receive(:post).and_return(http_response({}))

      described_class.new.disconnect!

      expect(HTTParty).to have_received(:post).with(
        "https://mastodon.social/oauth/revoke",
        hash_including(body: hash_including(token: "an-access-token"))
      )
      expect(MastodonCredentials.connected?).to be(false)
    end

    # ⚠️ A disconnect that the owner asked for must not depend on the instance being reachable.
    it "clears the store even when the revoke fails" do
      allow(HTTParty).to receive(:post).and_raise(SocketError)

      described_class.new.disconnect!

      expect(MastodonCredentials.connected?).to be(false)
    end

    # ⚠️ A rack-timeout is not a StandardError, thus `rescue_with` does not catch it. The clear is
    # in an `ensure`, thus it runs anyway.
    it "clears the store when the revoke raises an exception that is not a StandardError" do
      stub_const("FakeRequestTimeout", Class.new(Exception))
      allow(HTTParty).to receive(:post).and_raise(FakeRequestTimeout)

      expect { described_class.new.disconnect! }.to raise_error(FakeRequestTimeout)
      expect(MastodonCredentials.connected?).to be(false)
    end

    it "gives the revoke a timeout" do
      allow(HTTParty).to receive(:post).and_return(http_response({}))

      described_class.new.disconnect!

      expect(HTTParty).to have_received(:post).with(anything, hash_including(timeout: described_class::REQUEST_TIMEOUT))
    end
  end

  describe "#post!" do
    let(:url) { "https://example.test/a-post/" }
    let(:status_key) { "mastodon:status:3kabc" }

    before do
      connect_account!
      $redis.del(status_key)
      allow(HTTParty).to receive(:post)
        .and_return(http_response({ id: "1", url: "https://mastodon.social/@me/1" }))
    end

    after { $redis.del(status_key) }

    def post!(**overrides)
      described_class.new.post!(**{ text: "Read this", url: url, idempotency_key: "3kabc" }.merge(overrides))
    end

    it "refuses when no account is connected" do
      MastodonCredentials.clear

      expect { post! }.to raise_error(/not connected/)
    end

    # ⚠️ The URL goes in the TEXT here, and Bluesky puts it in an embed. Mastodon renders a link
    # inline and makes its own preview card from the og: tags of that page.
    it "puts the link in the status, below the body" do
      post!

      expect(HTTParty).to have_received(:post).with(
        "https://mastodon.social/api/v1/statuses",
        hash_including(body: hash_including(status: "Read this\n\n#{url}"))
      )
    end

    it "posts the body alone when there is no link" do
      post!(url: nil)

      expect(HTTParty).to have_received(:post).with(
        anything, hash_including(body: hash_including(status: "Read this"))
      )
    end

    # ⚠️ This header is what makes a quick retry safe: the instance answers with the status that it
    # made already, in place of a second one. MastodonPostJob sends the same key at each attempt.
    it "sends the idempotency key and the bearer token" do
      post!

      expect(HTTParty).to have_received(:post).with(
        anything,
        hash_including(headers: {
          "Authorization" => "Bearer an-access-token",
          "Idempotency-Key" => "3kabc"
        })
      )
    end

    it "omits the header when the caller gives no key" do
      post!(idempotency_key: nil)

      expect(HTTParty).to have_received(:post).with(
        anything, hash_including(headers: { "Authorization" => "Bearer an-access-token" })
      )
    end

    it "posts in public and in English" do
      post!

      expect(HTTParty).to have_received(:post).with(
        anything, hash_including(body: hash_including(visibility: "public", language: "en"))
      )
    end

    # ⚠️ It answers with the id as well as the URL. A thread names the status above it by its id.
    it "answers with the id and the URL of the status" do
      expect(post!).to eq({ "id" => "1", "url" => "https://mastodon.social/@me/1" })
    end

    # ⚠️ The instance keeps the idempotency key for approximately an hour, and the Sidekiq retries
    # go on for 24. The status in Redis is what makes a late retry safe.
    it "remembers the status below the key" do
      post!

      expect(JSON.parse($redis.get(status_key)))
        .to eq({ "id" => "1", "url" => "https://mastodon.social/@me/1" })
      expect($redis.ttl(status_key)).to be_within(60).of(described_class::STATUS_TTL.to_i)
    end

    it "answers with the status of an earlier attempt and posts nothing" do
      $redis.set(status_key, { "id" => "1", "url" => "https://mastodon.social/@me/1" }.to_json)

      expect(post!).to eq({ "id" => "1", "url" => "https://mastodon.social/@me/1" })
      expect(HTTParty).not_to have_received(:post)
    end

    # ⚠️ An earlier version of this code kept the URL alone. That value has no id, thus a reply
    # cannot name it, and the post is already out. It must not post a second time.
    it "reads a remembered value from before the id, and posts nothing" do
      $redis.set(status_key, "https://mastodon.social/@me/1")

      expect(post!).to eq({ "id" => nil, "url" => "https://mastodon.social/@me/1" })
      expect(HTTParty).not_to have_received(:post)
    end

    it "remembers nothing with no key" do
      post!(idempotency_key: nil)

      expect($redis.get(status_key)).to be_nil
    end

    it "refuses a draft with no body and no link" do
      expect { post!(text: "  ", url: nil) }.to raise_error(/empty/)
    end

    # ⚠️ It raises and does not fail soft, thus MastodonPostJob does the work again.
    it "raises when the instance refuses the status" do
      allow(HTTParty).to receive(:post).and_return(http_response({ error: "no" }, success: false, code: 422))

      expect { post! }.to raise_error(ApplicationService::HttpError)
    end
  end
end
