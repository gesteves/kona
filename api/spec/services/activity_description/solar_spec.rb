require "rails_helper"

RSpec.describe ActivityDescription::Solar do
  it "knows the day from the night at the equator" do
    expect(described_class.daylight?(Time.utc(2026, 3, 20, 12), 0.0, 0.0)).to be(true)
    expect(described_class.daylight?(Time.utc(2026, 3, 20, 0), 0.0, 0.0)).to be(false)
  end

  it "uses the longitude, and not the hour in UTC" do
    expect(described_class.daylight?(Time.utc(2026, 3, 20, 12), 46.0, -120.0)).to be(false)
    expect(described_class.daylight?(Time.utc(2026, 3, 20, 20), 46.0, -120.0)).to be(true)
  end

  it "knows the midnight sun and the polar night" do
    expect(described_class.daylight?(Time.utc(2026, 6, 21, 0), 80.0, 0.0)).to be(true)
    expect(described_class.daylight?(Time.utc(2026, 12, 21, 12), 80.0, 0.0)).to be(false)
  end
end
