require "rails_helper"

RSpec.describe StravaCredentials do
  include ActiveSupport::Testing::TimeHelpers

  before { $redis.del(described_class::REDIS_KEY) }

  after { $redis.del(described_class::REDIS_KEY) }

  def connect!(expires_at: 6.hours.from_now.to_i)
    described_class.store_athlete(
      athlete_id: 12_345, athlete_name: "A Rider",
      access_token: "an-access-token", refresh_token: "a-refresh-token", expires_at: expires_at
    )
  end

  describe ".store_athlete and .fetch" do
    it "round-trips the athlete and the tokens" do
      travel_to(Time.utc(2026, 10, 4, 12, 0, 0)) do
        connect!

        credentials = described_class.fetch

        expect(credentials.access_token).to eq("an-access-token")
        expect(credentials.refresh_token).to eq("a-refresh-token")
        expect(credentials.expires_at).to eq(6.hours.from_now)
        expect(credentials.athlete_id).to eq("12345")
        expect(credentials.athlete_name).to eq("A Rider")
        expect(credentials).to be_usable
        expect(described_class.connected?).to be(true)
      end
    end

    # ⚠️ The tokens can edit each activity of the athlete, and this Redis also holds the Sidekiq
    # queues.
    it "never writes a token in the clear" do
      connect!

      expect($redis.hget(described_class::REDIS_KEY, "access_token")).not_to include("an-access-token")
      expect($redis.hget(described_class::REDIS_KEY, "refresh_token")).not_to include("a-refresh-token")
    end

    it "gives nil members and no connection for an empty store" do
      credentials = described_class.fetch

      expect(credentials.access_token).to be_nil
      expect(credentials.expires_at).to be_nil
      expect(credentials).not_to be_usable
      expect(described_class.connected?).to be(false)
    end
  end

  describe ".store_tokens" do
    # ⚠️ Strava can give a new refresh token at each refresh, and the old one then stops working.
    it "replaces both tokens and keeps the athlete" do
      connect!

      described_class.store_tokens(access_token: "a-new-access-token", refresh_token: "a-new-refresh-token",
                                   expires_at: 6.hours.from_now.to_i)

      credentials = described_class.fetch
      expect(credentials.access_token).to eq("a-new-access-token")
      expect(credentials.refresh_token).to eq("a-new-refresh-token")
      expect(credentials.athlete_name).to eq("A Rider")
    end

    it "clears a recorded refresh failure, because a token that arrives is the correction" do
      connect!
      described_class.record_refresh_error(401)

      described_class.store_tokens(access_token: "a", refresh_token: "b", expires_at: 6.hours.from_now.to_i)

      expect(described_class.fetch.refresh_error).to be_nil
    end
  end

  describe "#stale?" do
    it "is false for a token that expires after the margin" do
      connect!(expires_at: 6.hours.from_now.to_i)

      expect(described_class.fetch.stale?(5.minutes)).to be(false)
    end

    it "is true for a token that expires within the margin" do
      connect!(expires_at: 2.minutes.from_now.to_i)

      expect(described_class.fetch.stale?(5.minutes)).to be(true)
    end

    it "is true with no access token and with an expiry time that Ruby cannot read" do
      expect(described_class.fetch.stale?(5.minutes)).to be(true)

      connect!
      $redis.hset(described_class::REDIS_KEY, "expires_at", "not-a-time")

      expect(described_class.fetch.stale?(5.minutes)).to be(true)
    end
  end

  describe ".record_refresh_error" do
    before { connect! }

    it "records a 4xx, which means the token is dead" do
      described_class.record_refresh_error(401)

      expect(described_class.fetch.refresh_error).to include(code: 401)
    end

    # ⚠️ A 5xx means Strava is away, and not that the token is dead. The next refresh recovers.
    it "ignores a 5xx" do
      described_class.record_refresh_error(503)

      expect(described_class.fetch.refresh_error).to be_nil
    end
  end

  describe ".clear" do
    it "forgets the athlete" do
      connect!

      described_class.clear

      expect(described_class.connected?).to be(false)
      expect(described_class.fetch.athlete_name).to be_nil
    end
  end

  # ⚠️ A new RAILS_MASTER_KEY must give "not connected", and it must not raise on each page that
  # shows the connection status.
  describe "an undecryptable token" do
    it "is treated as absent rather than raising" do
      connect!
      $redis.hset(described_class::REDIS_KEY, "refresh_token", "not-a-valid-message")

      expect { described_class.fetch }.not_to raise_error
      expect(described_class.fetch).not_to be_usable
      expect(described_class.connected?).to be(false)
    end
  end
end
