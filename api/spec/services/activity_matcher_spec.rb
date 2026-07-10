require "rails_helper"

RSpec.describe ActivityMatcher do
  describe ".normalize_type" do
    it "maps Intervals.icu and Whoop type names to the shared set" do
      expect(described_class.normalize_type("Ride")).to eq("Cycling")
      expect(described_class.normalize_type("VirtualRide")).to eq("Cycling")
      expect(described_class.normalize_type("spin")).to eq("Cycling")
      expect(described_class.normalize_type("OpenWaterSwim")).to eq("Swimming")
      expect(described_class.normalize_type("WeightTraining")).to eq("Strength")
      expect(described_class.normalize_type("Functional Fitness")).to eq("Strength")
      expect(described_class.normalize_type("HIIT")).to eq("Strength")
    end

    it "collapses underscores and hyphens before lookup" do
      expect(described_class.normalize_type("functional_fitness")).to eq("Strength")
      expect(described_class.normalize_type("cross-country-skiing")).to eq("Skiing")
    end

    it "returns Other for unknown or blank types" do
      expect(described_class.normalize_type("Pickleball")).to eq("Other")
      expect(described_class.normalize_type(nil)).to eq("Other")
      expect(described_class.normalize_type("")).to eq("Other")
    end
  end

  describe ".compatible_types?" do
    it "matches identical types and treats Other as a wildcard" do
      expect(described_class.compatible_types?("Cycling", "Cycling")).to be(true)
      expect(described_class.compatible_types?("Other", "Running")).to be(true)
      expect(described_class.compatible_types?("Swimming", "Other")).to be(true)
      expect(described_class.compatible_types?("Cycling", "Running")).to be(false)
    end
  end

  describe ".matches?" do
    let(:timezone) { "America/Denver" }
    let(:workout) do
      { id: "w1", activity_type: "Cycling", start_time: Time.iso8601("2026-07-09T13:30:00Z"), strain: 10.0 }
    end

    def icu_activity(start_local, type: "Ride", extra: {})
      { id: "i1", type: type, start_date_local: start_local }.merge(extra)
    end

    it "matches when start times are within 5 truncated minutes and types agree" do
      # 13:30Z is 07:30 local; 5:59 apart still truncates to 5 minutes.
      expect(described_class.matches?(icu_activity("2026-07-09T07:35:59"), workout, timezone)).to be(true)
    end

    it "rejects a 6-minute gap" do
      expect(described_class.matches?(icu_activity("2026-07-09T07:36:00"), workout, timezone)).to be(false)
    end

    it "rejects incompatible types even at identical start times" do
      expect(described_class.matches?(icu_activity("2026-07-09T07:30:00", type: "Run"), workout, timezone)).to be(false)
    end

    it "lets an unknown ICU type (Other) match anything" do
      expect(described_class.matches?(icu_activity("2026-07-09T07:30:00", type: "Yoga"), workout, timezone)).to be(true)
    end

    it "never matches Strava-only imports" do
      strava = icu_activity("2026-07-09T07:30:00", extra: { source: "STRAVA", _note: "unavailable" })
      expect(described_class.matches?(strava, workout, timezone)).to be(false)
    end

    it "rejects activities without a local start time" do
      expect(described_class.matches?({ id: "i1", type: "Ride" }, workout, timezone)).to be(false)
    end
  end
end
