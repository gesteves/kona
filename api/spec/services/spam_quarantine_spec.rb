require "rails_helper"

RSpec.describe SpamQuarantine do
  # A plain Hash standing in for the Redis hash, so the pruning, ordering, and take-once logic run
  # for real rather than against a pile of individually stubbed return values.
  let(:store) { {} }

  before do
    allow($redis).to receive(:hset) { |_key, field, value| store[field] = value }
    allow($redis).to receive(:hget) { |_key, field| store[field] }
    allow($redis).to receive(:hgetall) { store.dup }
    allow($redis).to receive(:hlen) { store.size }
    allow($redis).to receive(:hdel) { |_key, *fields| fields.count { |f| !store.delete(f).nil? } }
  end

  # Writes an entry straight into the fake store, bypassing #store so the timestamp can be forced.
  def seed(id:, received_at:, name: "Spammer", context: {})
    store[id] = {
      "id" => id, "name" => name, "email" => "spam@example.com", "message" => "buy now",
      "context" => context, "received_at" => received_at.utc.iso8601
    }.to_json
  end

  describe "#store" do
    it "writes the submission under a generated id and returns it" do
      id = described_class.new.store(name: "Ivan", email: "ivan@example.com",
        message: "cheap pills", context: { "ip" => "203.0.113.7" })

      expect(id).to be_present
      payload = JSON.parse(store.fetch(id))
      expect(payload).to include(
        "id" => id,
        "name" => "Ivan",
        "email" => "ivan@example.com",
        "message" => "cheap pills",
        "context" => { "ip" => "203.0.113.7" }
      )
      expect(payload["received_at"]).to be_present
    end

    it "tolerates a nil context" do
      id = described_class.new.store(name: "Ivan", email: "ivan@example.com", message: "hi", context: nil)

      expect(JSON.parse(store.fetch(id))["context"]).to eq({})
    end

    # Pruning on the write path is what bounds growth when nobody opens the page.
    it "drops expired entries as it writes" do
      seed(id: "old", received_at: 31.days.ago)

      described_class.new.store(name: "Ivan", email: "ivan@example.com", message: "hi")

      expect(store.keys).not_to include("old")
    end

    it "trims back to MAX_ENTRIES oldest-first" do
      stub_const("#{described_class}::MAX_ENTRIES", 2)
      seed(id: "oldest", received_at: 3.days.ago)
      seed(id: "middle", received_at: 2.days.ago)
      seed(id: "newest", received_at: 1.day.ago)

      described_class.new.store(name: "Ivan", email: "ivan@example.com", message: "hi")

      expect(store.keys).not_to include("oldest", "middle")
      expect(store.keys).to include("newest")
    end
  end

  describe "#all" do
    it "returns the messages newest first" do
      seed(id: "older", received_at: 2.days.ago)
      seed(id: "newer", received_at: 1.hour.ago)

      expect(described_class.new.all.map { |m| m["id"] }).to eq(%w[newer older])
    end

    it "drops entries past the retention window, in Redis as well as in the result" do
      seed(id: "expired", received_at: 31.days.ago)
      seed(id: "fresh", received_at: 1.day.ago)

      expect(described_class.new.all.map { |m| m["id"] }).to eq([ "fresh" ])
      expect(store.keys).to eq([ "fresh" ])
    end

    # One bad field must not take down the whole page.
    it "drops an unparseable entry rather than raising" do
      store["broken"] = "{not json"
      seed(id: "fine", received_at: 1.day.ago)

      expect(described_class.new.all.map { |m| m["id"] }).to eq([ "fine" ])
      expect(store.keys).to eq([ "fine" ])
    end

    it "drops an entry with an unusable timestamp" do
      store["undated"] = { "id" => "undated", "received_at" => "whenever" }.to_json

      expect(described_class.new.all).to be_empty
    end

    it "is empty when nothing is quarantined" do
      expect(described_class.new.all).to eq([])
    end
  end

  describe "#take" do
    it "returns the message and removes it" do
      seed(id: "abc", received_at: 1.day.ago, name: "Ivan")

      expect(described_class.new.take("abc")).to include("id" => "abc", "name" => "Ivan")
      expect(store).not_to have_key("abc")
    end

    # ⚠️ The whole point of fetch-and-remove: a double click must not deliver the email twice.
    it "returns nil on a second call for the same id" do
      seed(id: "abc", received_at: 1.day.ago)
      quarantine = described_class.new

      expect(quarantine.take("abc")).to be_present
      expect(quarantine.take("abc")).to be_nil
    end

    it "returns nil for an unknown id" do
      expect(described_class.new.take("nope")).to be_nil
    end
  end

  describe "#delete" do
    it "reports whether anything was removed" do
      seed(id: "abc", received_at: 1.day.ago)
      quarantine = described_class.new

      expect(quarantine.delete("abc")).to be true
      expect(quarantine.delete("abc")).to be false
    end
  end

  describe "#count" do
    it "counts what's in the hash" do
      seed(id: "a", received_at: 1.day.ago)
      seed(id: "b", received_at: 2.days.ago)

      expect(described_class.new.count).to eq(2)
    end
  end
end
