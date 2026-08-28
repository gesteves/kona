require "rails_helper"

RSpec.describe ThreadsCredentials do
  include ActiveSupport::Testing::TimeHelpers

  before { $redis.del(described_class::REDIS_KEY) }

  after { $redis.del(described_class::REDIS_KEY) }

  def connect!(expires_in: 60.days.to_i)
    described_class.store_account(
      access_token: "a-long-lived-token", expires_in: expires_in,
      user_id: "12345", username: "me"
    )
  end

  describe ".store_account and .fetch" do
    it "round-trips the account" do
      connect!

      credentials = described_class.fetch

      expect(credentials.access_token).to eq("a-long-lived-token")
      expect(credentials.user_id).to eq("12345")
      expect(credentials.username).to eq("me")
      expect(credentials).to be_usable
      expect(described_class.connected?).to be(true)
    end

    # ⚠️ The token posts as the owner, and this Redis also holds the Sidekiq queues.
    it "never writes the access token in the clear" do
      connect!

      expect($redis.hget(described_class::REDIS_KEY, "access_token")).not_to include("a-long-lived-token")
    end

    it "records when the token was issued and when it expires" do
      travel_to(Time.utc(2026, 8, 28, 12, 0, 0)) do
        connect!

        credentials = described_class.fetch
        expect(credentials.issued_at).to eq(Time.current.change(usec: 0))
        expect(credentials.expires_at).to eq(60.days.from_now.change(usec: 0))
      end
    end
  end

  describe ".store_access_token" do
    it "replaces the token and keeps the account" do
      connect!

      described_class.store_access_token(access_token: "a-renewed-token", expires_in: 60.days.to_i)

      credentials = described_class.fetch
      expect(credentials.access_token).to eq("a-renewed-token")
      expect(credentials.username).to eq("me")
    end

    it "clears a recorded refresh failure, because a token that arrives is the correction" do
      connect!
      described_class.record_refresh_error(400)

      described_class.store_access_token(access_token: "a-renewed-token", expires_in: 60.days.to_i)

      expect(described_class.fetch.refresh_error).to be_nil
    end
  end

  describe "#refreshable?" do
    # ⚠️ Meta refuses a refresh before the token is 24 hours old. That must never look like a
    # failure.
    it "is false while the token is too new" do
      connect!

      expect(described_class.fetch).not_to be_refreshable
    end

    it "is true once the token is old enough" do
      connect!
      $redis.hset(described_class::REDIS_KEY, "issued_at", 2.days.ago.utc.iso8601)

      expect(described_class.fetch).to be_refreshable
    end
  end

  describe "#expired?" do
    it "is false for a token inside its window" do
      connect!

      expect(described_class.fetch).not_to be_expired
    end

    # ⚠️ An expired Threads token is dead for all time. Only a new authorization corrects it.
    it "is true once the window closed" do
      connect!
      $redis.hset(described_class::REDIS_KEY, "expires_at", 1.hour.ago.utc.iso8601)

      expect(described_class.fetch).to be_expired
    end
  end

  describe ".record_refresh_error" do
    before { connect! }

    it "records a 4xx, which means the token is dead" do
      described_class.record_refresh_error(400)

      expect(described_class.fetch.refresh_error).to include(code: 400)
    end

    # ⚠️ A 5xx means Meta is away, and not that the token is dead. The next run recovers.
    it "ignores a 5xx" do
      described_class.record_refresh_error(503)

      expect(described_class.fetch.refresh_error).to be_nil
    end
  end

  describe ".clear" do
    it "forgets the account" do
      connect!

      described_class.clear

      expect(described_class.connected?).to be(false)
      expect(described_class.fetch.username).to be_nil
    end
  end

  # ⚠️ A new RAILS_MASTER_KEY must give "not connected", and it must not raise on each page that
  # shows the connection status.
  describe "an undecryptable token" do
    it "is treated as absent rather than raising" do
      connect!
      $redis.hset(described_class::REDIS_KEY, "access_token", "not-a-valid-message")

      expect { described_class.fetch }.not_to raise_error
      expect(described_class.fetch).not_to be_usable
      expect(described_class.connected?).to be(false)
    end
  end
end
