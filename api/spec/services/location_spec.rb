require "rails_helper"

RSpec.describe Location do
  def with_location(env:, redis: nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("LOCATION").and_return(env)
    allow($redis).to receive(:get).with(described_class::LOCATION_CACHE_KEY).and_return(redis)
    described_class.new
  end

  describe "resolving the current location" do
    it "prefers a valid LOCATION over the value in Redis" do
      location = with_location(env: "43.48,-110.76", redis: "37.77,-122.42")

      expect(location.latitude).to eq(43.48)
      expect(location.longitude).to eq(-110.76)
    end

    it "falls back to Redis when LOCATION is unset" do
      location = with_location(env: nil, redis: "37.77,-122.42")

      expect(location.latitude).to eq(37.77)
      expect(location.longitude).to eq(-122.42)
    end

    # to_f changes text that it cannot parse into 0.0, which is a correct coordinate. Thus a LOCATION
    # with a typing error would give the point at 0, 0, *and* it would replace the correct value in
    # Redis, and nothing would go into the log.
    it "falls back to Redis when LOCATION is not a coordinate pair" do
      location = with_location(env: "somewhere,else", redis: "37.77,-122.42")

      expect(location.latitude).to eq(37.77)
      expect(location.longitude).to eq(-122.42)
    end

    it "falls back to Redis when LOCATION has only one component" do
      location = with_location(env: "43.48", redis: "37.77,-122.42")

      expect(location.latitude).to eq(37.77)
    end

    it "tolerates surrounding whitespace" do
      location = with_location(env: " 43.48 , -110.76 ")

      expect(location.latitude).to eq(43.48)
      expect(location.longitude).to eq(-110.76)
    end

    it "is blank when neither source has a usable value" do
      location = with_location(env: nil, redis: nil)

      expect(location.latitude).to be_nil
      expect(location.longitude).to be_nil
    end

    it "rejects an out-of-range pair from Redis" do
      location = with_location(env: nil, redis: "91.0,-122.42")

      expect(location.latitude).to be_nil
    end
  end

  describe ".valid_coordinates?" do
    it "accepts coordinates inside the valid ranges" do
      expect(described_class.valid_coordinates?(43.48, -110.76)).to be(true)
    end

    it "accepts the range boundaries" do
      expect(described_class.valid_coordinates?(90, 180)).to be(true)
      expect(described_class.valid_coordinates?(-90, -180)).to be(true)
    end

    it "rejects out-of-range values" do
      expect(described_class.valid_coordinates?(90.1, 0)).to be(false)
      expect(described_class.valid_coordinates?(0, 180.1)).to be(false)
    end

    it "rejects a missing component" do
      expect(described_class.valid_coordinates?(nil, -110.76)).to be(false)
      expect(described_class.valid_coordinates?(43.48, nil)).to be(false)
    end
  end

  describe ".parse" do
    it "returns the pair as floats" do
      expect(described_class.parse("43.48", "-110.76")).to eq([ 43.48, -110.76 ])
    end

    it "keeps a zero, which is a real coordinate" do
      expect(described_class.parse("0", "0")).to eq([ 0.0, 0.0 ])
    end

    # to_f would make each of these 0.0, which is a correct coordinate in the Gulf of Guinea, and
    # the app would store it.
    it "rejects text rather than coercing it to Null Island" do
      expect(described_class.parse("somewhere", "else")).to be_nil
    end

    it "rejects an out-of-range pair" do
      expect(described_class.parse("91", "0")).to be_nil
    end

    it "rejects a missing component" do
      expect(described_class.parse("43.48", nil)).to be_nil
      expect(described_class.parse("43.48", "")).to be_nil
    end
  end

  describe ".stored" do
    it "reads the coordinates in Redis, ignoring the override" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("LOCATION").and_return("43.48,-110.76")
      allow($redis).to receive(:get).with(described_class::LOCATION_CACHE_KEY).and_return("37.77,-122.42")

      expect(described_class.stored).to eq([ 37.77, -122.42 ])
    end

    it "is nil when nothing is stored" do
      allow($redis).to receive(:get).with(described_class::LOCATION_CACHE_KEY).and_return(nil)

      expect(described_class.stored).to be_nil
    end
  end

  describe ".store" do
    # ⚠️ Write to Redis first: the widgets read the stored value, and it must not wait for the
    # sync.
    it "writes the coordinates and enqueues the sync" do
      expect($redis).to receive(:set).with(described_class::LOCATION_CACHE_KEY, "37.77,-122.42")

      described_class.store(37.77, -122.42)

      expect(LocationSyncJob).to have_enqueued_sidekiq_job(37.77, -122.42)
    end
  end
end
