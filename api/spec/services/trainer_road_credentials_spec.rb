require "rails_helper"

RSpec.describe TrainerRoadCredentials do
  let(:url) { "https://www.trainerroad.com/app/calendar/00000000-0000-4000-8000-000000000000" }

  before { $redis.del(described_class::REDIS_KEY) }

  after { $redis.del(described_class::REDIS_KEY) }

  describe ".store and .fetch" do
    it "round-trips a stored URL" do
      described_class.store(calendar_url: url)

      expect(described_class.fetch).to eq(url)
    end

    it "trims the URL" do
      described_class.store(calendar_url: "  #{url}  ")

      expect(described_class.fetch).to eq(url)
    end

    # ⚠️ The GUID at the end of the URL is the credential, and this Redis also holds the Sidekiq
    # queues. Thus nobody must be able to read it there.
    it "never writes the URL in the clear" do
      described_class.store(calendar_url: url)

      expect($redis.hget(described_class::REDIS_KEY, "calendar_url")).not_to include("00000000")
    end

    it "replaces an existing URL" do
      described_class.store(calendar_url: "https://example.test/old.ics")
      described_class.store(calendar_url: url)

      expect(described_class.fetch).to eq(url)
    end
  end

  describe ".stored?" do
    it "is false with nothing entered" do
      expect(described_class.stored?).to be(false)
      expect(described_class.fetch).to be_nil
    end

    it "is true once a URL is entered" do
      described_class.store(calendar_url: url)

      expect(described_class.stored?).to be(true)
    end
  end

  describe ".clear" do
    it "forgets the stored URL" do
      described_class.store(calendar_url: url)

      described_class.clear

      expect(described_class.stored?).to be(false)
      expect(described_class.fetch).to be_nil
    end
  end

  # ⚠️ A new RAILS_MASTER_KEY must give "not connected". It must not raise on each page that shows
  # the connection status.
  describe "an undecryptable URL" do
    it "is treated as absent rather than raising" do
      $redis.hset(described_class::REDIS_KEY, "calendar_url", "not-a-valid-message")

      expect { described_class.fetch }.not_to raise_error
      expect(described_class.fetch).to be_nil
      expect(described_class.stored?).to be(false)
    end
  end
end
