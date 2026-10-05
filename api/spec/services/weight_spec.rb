require "rails_helper"

RSpec.describe Weight do
  include ActiveSupport::Testing::TimeHelpers

  describe ".parse" do
    it "gives kilograms as they are, with kg as the default unit" do
      expect(described_class.parse("72.4")).to eq(72.4)
      expect(described_class.parse("72.4", "KG")).to eq(72.4)
    end

    it "converts pounds to kilograms" do
      expect(described_class.parse("160", "lb")).to eq(72.57)
    end

    it "gives nil for text, an unknown unit, or a value out of range" do
      expect(described_class.parse("abc")).to be_nil
      expect(described_class.parse("72.4", "stone")).to be_nil
      expect(described_class.parse("10")).to be_nil
      expect(described_class.parse("700", "lb")).to be_nil
    end
  end

  describe ".parse_date" do
    it "gives today in the time zone of the location when the value is blank" do
      allow_any_instance_of(Location).to receive(:time_zone).and_return("Asia/Tokyo")

      travel_to Time.utc(2026, 10, 5, 20, 0) do
        expect(described_class.parse_date(nil)).to eq(Date.new(2026, 10, 6))
      end
    end

    it "parses an ISO 8601 day, and gives nil for an incorrect one" do
      expect(described_class.parse_date("2026-10-01")).to eq(Date.new(2026, 10, 1))
      expect(described_class.parse_date("yesterday")).to be_nil
    end
  end
end
