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

    it "asks the named instance for a client, with the callback of this app" do
      allow(HTTParty).to receive(:post).and_return(http_response({ client_id: "abc", client_secret: "xyz" }))

      described_class.new.register!(instance: "mastodon.social", redirect_uri: redirect_uri)

      expect(HTTParty).to have_received(:post).with(
        "https://mastodon.social/api/v1/apps",
        hash_including(body: hash_including(redirect_uris: redirect_uri, scopes: described_class::SCOPES))
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
  end
end
