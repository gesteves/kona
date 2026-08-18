require "rails_helper"

RSpec.describe BlueskyCredentials do
  before do
    $redis.del(described_class::REDIS_KEY)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("BLUESKY_HANDLE").and_return(nil)
    allow(ENV).to receive(:[]).with("BLUESKY_APP_PASSWORD").and_return(nil)
  end

  after { $redis.del(described_class::REDIS_KEY) }

  describe ".store and .fetch" do
    it "round-trips a stored pair and reports it as coming from the admin" do
      described_class.store(handle: "me.bsky.social", app_password: "abcd-efgh-ijkl-mnop")

      credentials = described_class.fetch

      expect(credentials.handle).to eq("me.bsky.social")
      expect(credentials.app_password).to eq("abcd-efgh-ijkl-mnop")
      expect(credentials.source).to eq(:admin)
      expect(credentials).to be_usable
    end

    it "trims the handle" do
      described_class.store(handle: "  me.bsky.social  ", app_password: "pw")

      expect(described_class.fetch.handle).to eq("me.bsky.social")
    end

    # ⚠️ The app password is an account-level credential and this Redis also backs the Sidekiq
    # queues, so it must never be readable there.
    it "never writes the app password in the clear" do
      described_class.store(handle: "me.bsky.social", app_password: "abcd-efgh-ijkl-mnop")

      expect($redis.hget(described_class::REDIS_KEY, "app_password")).not_to include("abcd-efgh-ijkl-mnop")
    end

    it "replaces an existing pair" do
      described_class.store(handle: "old.bsky.social", app_password: "old")
      described_class.store(handle: "new.bsky.social", app_password: "new")

      expect(described_class.fetch.handle).to eq("new.bsky.social")
      expect(described_class.fetch.app_password).to eq("new")
    end
  end

  describe ".fetch precedence" do
    before do
      allow(ENV).to receive(:[]).with("BLUESKY_HANDLE").and_return("env.bsky.social")
      allow(ENV).to receive(:[]).with("BLUESKY_APP_PASSWORD").and_return("env-password")
    end

    it "falls back to the environment when nothing is stored" do
      credentials = described_class.fetch

      expect(credentials.handle).to eq("env.bsky.social")
      expect(credentials.app_password).to eq("env-password")
      expect(credentials.source).to eq(:environment)
    end

    it "prefers a stored pair over the environment" do
      described_class.store(handle: "stored.bsky.social", app_password: "stored-password")

      credentials = described_class.fetch

      expect(credentials.handle).to eq("stored.bsky.social")
      expect(credentials.source).to eq(:admin)
    end

    it "falls back to the environment when only half a pair is stored" do
      $redis.hset(described_class::REDIS_KEY, "handle", "half.bsky.social")

      expect(described_class.fetch.source).to eq(:environment)
    end
  end

  describe ".fetch with nothing available" do
    it "reports no source" do
      credentials = described_class.fetch

      expect(credentials).not_to be_usable
      expect(credentials.source).to be_nil
    end
  end

  describe ".stored?" do
    it "is false for the environment pair alone" do
      allow(ENV).to receive(:[]).with("BLUESKY_HANDLE").and_return("env.bsky.social")
      allow(ENV).to receive(:[]).with("BLUESKY_APP_PASSWORD").and_return("env-password")

      expect(described_class.stored?).to be(false)
    end

    it "is true once a pair is entered" do
      described_class.store(handle: "me.bsky.social", app_password: "pw")

      expect(described_class.stored?).to be(true)
    end
  end

  describe ".clear" do
    it "forgets the stored pair and falls back to the environment" do
      described_class.store(handle: "stored.bsky.social", app_password: "stored-password")
      allow(ENV).to receive(:[]).with("BLUESKY_HANDLE").and_return("env.bsky.social")
      allow(ENV).to receive(:[]).with("BLUESKY_APP_PASSWORD").and_return("env-password")

      described_class.clear

      expect(described_class.stored?).to be(false)
      expect(described_class.fetch.source).to eq(:environment)
    end
  end

  # ⚠️ A rotated RAILS_MASTER_KEY must degrade to "not connected", not raise on every page that
  # renders the connection status.
  describe "an undecryptable password" do
    it "is treated as absent rather than raising" do
      $redis.hset(described_class::REDIS_KEY, "handle", "me.bsky.social", "app_password", "not-a-valid-message")

      expect { described_class.fetch }.not_to raise_error
      expect(described_class.fetch).not_to be_usable
      expect(described_class.stored?).to be(false)
    end
  end
end
