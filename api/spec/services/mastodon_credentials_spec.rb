require "rails_helper"

RSpec.describe MastodonCredentials do
  let(:redirect_uri) { "https://admin.example.test/connected-apps/mastodon/callback" }

  before { $redis.del(described_class::REDIS_KEY) }

  after { $redis.del(described_class::REDIS_KEY) }

  def store_client!(instance: "mastodon.social")
    described_class.store_client(
      instance: instance, client_id: "client-id", client_secret: "client-secret",
      redirect_uri: redirect_uri
    )
  end

  describe ".store_client and .fetch" do
    it "round-trips the client" do
      store_client!

      credentials = described_class.fetch

      expect(credentials.instance).to eq("mastodon.social")
      expect(credentials.client_id).to eq("client-id")
      expect(credentials.client_secret).to eq("client-secret")
      expect(credentials.redirect_uri).to eq(redirect_uri)
      expect(credentials).to be_registered
      expect(credentials).not_to be_usable
    end

    # ⚠️ The client secret and the access token are account credentials, and this Redis also holds
    # the Sidekiq queues. Thus nobody must be able to read them there.
    it "never writes the client secret in the clear" do
      store_client!

      expect($redis.hget(described_class::REDIS_KEY, "client_secret")).not_to include("client-secret")
    end

    # ⚠️ Without this, an owner who names a second instance keeps the token of the first one, and
    # the page shows "Connected" for an account that the new client cannot reach.
    it "drops the token and the handle of the account that was connected" do
      store_client!
      described_class.store_token(access_token: "old-token", handle: "@me@mastodon.social")

      store_client!(instance: "other.social")

      credentials = described_class.fetch
      expect(credentials.instance).to eq("other.social")
      expect(credentials.access_token).to be_nil
      expect(credentials.handle).to be_nil
      expect(described_class.connected?).to be(false)
    end
  end

  describe ".store_token" do
    it "completes the connection" do
      store_client!

      described_class.store_token(access_token: "an-access-token", handle: "@me@mastodon.social")

      credentials = described_class.fetch
      expect(credentials.access_token).to eq("an-access-token")
      expect(credentials.handle).to eq("@me@mastodon.social")
      expect(credentials).to be_usable
      expect(described_class.connected?).to be(true)
    end

    it "never writes the access token in the clear" do
      store_client!
      described_class.store_token(access_token: "an-access-token", handle: "@me@mastodon.social")

      expect($redis.hget(described_class::REDIS_KEY, "access_token")).not_to include("an-access-token")
    end
  end

  describe ".connected?" do
    it "is false with nothing stored" do
      expect(described_class.connected?).to be(false)
      expect(described_class.fetch).not_to be_registered
    end

    # A token with no client cannot refresh and cannot revoke, thus it is not a connection.
    it "is false when only the token is present" do
      described_class.store_token(access_token: "an-access-token", handle: "@me@mastodon.social")

      expect(described_class.connected?).to be(false)
    end
  end

  describe ".clear" do
    it "forgets the client and the token" do
      store_client!
      described_class.store_token(access_token: "an-access-token", handle: "@me@mastodon.social")

      described_class.clear

      expect(described_class.connected?).to be(false)
      expect(described_class.fetch.instance).to be_nil
    end
  end

  # ⚠️ A new RAILS_MASTER_KEY must give "not connected". It must not raise on each page that shows
  # the connection status.
  describe "an undecryptable secret" do
    it "is treated as absent rather than raising" do
      store_client!
      $redis.hset(described_class::REDIS_KEY, "access_token", "not-a-valid-message")

      expect { described_class.fetch }.not_to raise_error
      expect(described_class.fetch).not_to be_usable
      expect(described_class.connected?).to be(false)
    end
  end
end
