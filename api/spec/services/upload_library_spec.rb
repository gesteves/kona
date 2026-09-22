require "rails_helper"

RSpec.describe UploadLibrary do
  subject(:library) { described_class.new }

  before { $redis.del(described_class::REDIS_KEY) }
  after  { $redis.del(described_class::REDIS_KEY) }

  def stage(id = SecureRandom.hex(16), title: "IMG_4821")
    library.stage(id: id, title: title, alt: "A dog running on a beach.", file_name: "#{title}.jpg")
  end

  describe "#stage" do
    it "writes a record that starts at processing" do
      id = stage

      expect(library.find(id)).to include(
        "id" => id, "title" => "IMG_4821", "alt" => "A dog running on a beach.",
        "file_name" => "IMG_4821.jpg", "status" => "processing", "asset_id" => nil, "error" => nil
      )
    end

    # ⚠️ "processing" is the word that job_status_controller.js compares against. A store that
    # uses another word polls for all time.
    it "uses the word that the poll of the page reads" do
      expect(described_class::STATUSES).to include("processing")
      expect(library.find(stage)["status"]).to eq("processing")
    end
  end

  describe "#all and #statuses" do
    it "gives the newest record first" do
      old = stage(title: "Old")
      library.update(old, "uploaded_at" => 1.hour.ago.utc.iso8601)
      recent = stage(title: "Recent")

      expect(library.all.map { |record| record["id"] }).to eq([ recent, old ])
    end

    it "gives the status of each record and not the records" do
      first = stage
      second = stage
      library.update(second, "status" => "published")

      expect(library.statuses).to eq(first => "processing", second => "published")
    end
  end

  describe "#update" do
    it "puts the changes on top of the record, and gives nil for one that is gone" do
      id = stage

      expect(library.update(id, "status" => "failed", "error" => "nope"))
        .to include("status" => "failed", "error" => "nope", "title" => "IMG_4821")
      expect(library.update("0" * 32, "status" => "failed")).to be_nil
    end
  end

  describe "the prune" do
    # This is a receipt and not a thing that the owner opens again, thus both limits apply.
    it "keeps at most MAX_ENTRIES records" do
      stub_const("UploadLibrary::MAX_ENTRIES", 3)
      5.times { |index| library.update(stage, "uploaded_at" => index.minutes.ago.utc.iso8601) }

      expect(library.count).to be <= 3
    end

    it "removes a record past MAX_AGE" do
      old = stage(title: "Old")
      library.update(old, "uploaded_at" => (described_class::MAX_AGE + 1.day).ago.utc.iso8601)

      stage(title: "Recent")

      expect(library.find(old)).to be_nil
    end

    # A record with no date, or with one that Ruby cannot read, is not fresh.
    it "removes a record whose date it cannot read" do
      bad = stage(title: "Bad")
      library.update(bad, "uploaded_at" => "not a date")

      stage(title: "Recent")

      expect(library.find(bad)).to be_nil
    end
  end
end
