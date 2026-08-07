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

    # to_f coerces unparseable text to 0.0, which is a valid coordinate — so a typo'd LOCATION
    # would resolve to Null Island *and* outrank the good value in Redis, with nothing logged.
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
end
