require "rails_helper"

RSpec.describe TimeHelper do
  def helper_with(time_zone: nil)
    Class.new { include TimeHelper }.new.tap do |h|
      h.instance_variable_set(:@time_zone, time_zone)
    end
  end

  describe "#location_time_zone" do
    it "uses the controller-resolved @time_zone when present" do
      expect(helper_with(time_zone: "America/New_York").location_time_zone).to eq("America/New_York")
    end

    it "falls back to TIME_ZONE / America/Denver when unset" do
      expect(helper_with.location_time_zone).to eq(ENV.fetch("TIME_ZONE", "America/Denver"))
    end
  end

  describe "#current_time" do
    it "is in the resolved time zone" do
      expect(helper_with(time_zone: "America/New_York").current_time.time_zone.name).to eq("America/New_York")
    end
  end

  describe "#time_with_meridiem_abbr" do
    it "formats the time and wraps the meridiem in an <abbr>" do
      result = helper_with.time_with_meridiem_abbr("2024-01-01T14:30:00Z", "America/Denver")
      expect(result).to eq("07:30 <abbr>AM</abbr>")
    end

    it "returns nil when the time or zone is blank" do
      expect(helper_with.time_with_meridiem_abbr(nil, "America/Denver")).to be_nil
      expect(helper_with.time_with_meridiem_abbr("2024-01-01T14:30:00Z", nil)).to be_nil
    end
  end
end
