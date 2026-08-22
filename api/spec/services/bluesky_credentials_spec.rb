require "rails_helper"

RSpec.describe BlueskyCredentials do
  before { $redis.del(described_class::REDIS_KEY) }

  after { $redis.del(described_class::REDIS_KEY) }

  describe ".store and .fetch" do
    it "round-trips a stored pair and reports it as coming from the admin" do
      described_class.store(handle: "me.bsky.social", app_password: "abcd-efgh-ijkl-mnop")

      credentials = described_class.fetch

      expect(credentials.handle).to eq("me.bsky.social")
      expect(credentials.app_password).to eq("abcd-efgh-ijkl-mnop")
      expect(credentials).to be_usable
    end

    it "trims the handle" do
      described_class.store(handle: "  me.bsky.social  ", app_password: "pw")

      expect(described_class.fetch.handle).to eq("me.bsky.social")
    end

    # ⚠️ The app password is an account credential, and this Redis also holds the Sidekiq queues. Thus
    # nobody must be able to read it there.
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

  describe ".stored?" do
    it "is false with nothing entered" do
      expect(described_class.stored?).to be(false)
      expect(described_class.fetch).not_to be_usable
    end

    it "is false when only half a pair is present" do
      $redis.hset(described_class::REDIS_KEY, "handle", "half.bsky.social")

      expect(described_class.stored?).to be(false)
    end

    it "is true once a pair is entered" do
      described_class.store(handle: "me.bsky.social", app_password: "pw")

      expect(described_class.stored?).to be(true)
    end
  end

  describe ".clear" do
    it "forgets the stored pair" do
      described_class.store(handle: "stored.bsky.social", app_password: "stored-password")

      described_class.clear

      expect(described_class.stored?).to be(false)
      expect(described_class.fetch.handle).to be_nil
    end
  end

  # ⚠️ A new RAILS_MASTER_KEY must give "not connected". It must not raise on each page that shows
  # the connection status.
  describe "an undecryptable password" do
    it "is treated as absent rather than raising" do
      $redis.hset(described_class::REDIS_KEY, "handle", "me.bsky.social", "app_password", "not-a-valid-message")

      expect { described_class.fetch }.not_to raise_error
      expect(described_class.fetch).not_to be_usable
      expect(described_class.stored?).to be(false)
    end
  end
end
