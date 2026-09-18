require "rails_helper"

RSpec.describe TimeZoneResolver do
  describe ".call" do
    it "returns the geocoded timezone for valid coordinates" do
      allow(GoogleMaps).to receive(:new).with(43.48, -110.76)
        .and_return(instance_double(GoogleMaps, time_zone_id: "America/Denver"))

      expect(described_class.call(43.48, -110.76)).to eq("America/Denver")
    end

    it "falls back to the default when coordinates are blank (without geocoding)" do
      expect(GoogleMaps).not_to receive(:new)
      expect(described_class.call(nil, nil)).to eq(described_class.default)
    end

    it "falls back to the default when geocoding yields no timezone" do
      allow(GoogleMaps).to receive(:new).and_return(instance_double(GoogleMaps, time_zone_id: nil))
      expect(described_class.call(1.0, 2.0)).to eq(described_class.default)
    end
  end

  describe ".default" do
    before { allow(ENV).to receive(:[]).and_call_original }

    it "prefers the TIME_ZONE env var" do
      allow(ENV).to receive(:[]).with("TIME_ZONE").and_return("Europe/Paris")
      expect(described_class.default).to eq("Europe/Paris")
    end

    it "falls back to America/Denver" do
      allow(ENV).to receive(:[]).with("TIME_ZONE").and_return(nil)
      expect(described_class.default).to eq("America/Denver")
    end

    # A fly secret with no value arrives as an empty string, and `in_time_zone("")` raises.
    it "falls back to America/Denver for a blank value" do
      allow(ENV).to receive(:[]).with("TIME_ZONE").and_return("")
      expect(described_class.default).to eq("America/Denver")
    end
  end
end
