require "rails_helper"

RSpec.describe JsonHashStore do
  subject(:store) { described_class.new(key) }

  let(:key) { "spec:json_hash_store" }

  after { $redis.del(key) }

  it "writes, reads, counts, and deletes records by id" do
    store.write("a", { "n" => 1 })
    store.write("b", { "n" => 2 })

    expect(store.read("a")).to eq("n" => 1)
    expect(store.read("missing")).to be_nil
    expect(store.count).to eq(2)
    expect(store.delete("a")).to eq(1)
    expect(store.delete("a")).to eq(0)
    expect(store.read_all).to eq("b" => { "n" => 2 })
  end

  it "skips a record that it cannot read, and does not raise" do
    $redis.hset(key, "bad", "not json")
    $redis.hset(key, "list", "[1]")
    store.write("good", { "n" => 1 })

    expect(store.read("bad")).to be_nil
    expect(store.read_all.keys).to eq([ "good" ])
  end

  describe "#prune" do
    before do
      store.write("old", { "at" => "2026-01-01" })
      store.write("mid", { "at" => "2026-02-01" })
      store.write("new", { "at" => "2026-03-01" })
      $redis.hset(key, "bad", "{")
    end

    it "removes the unreadable, the refused, and the oldest above the limit, and gives the rest" do
      kept = store.prune(max: 1, sort_by: ->(r) { r["at"] }, keep: ->(r) { r["at"] > "2026-01-15" })

      expect(kept).to eq([ { "at" => "2026-03-01" } ])
      expect(store.read_all.keys).to eq([ "new" ])
    end

    it "keeps every readable record with no refusal and a large limit" do
      kept = store.prune(max: 10, sort_by: ->(r) { r["at"] })

      expect(kept.map { |r| r["at"] }).to contain_exactly("2026-01-01", "2026-02-01", "2026-03-01")
      expect(store.count).to eq(3)
    end
  end
end
