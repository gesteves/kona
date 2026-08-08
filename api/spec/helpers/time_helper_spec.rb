require "rails_helper"

RSpec.describe TimeHelper do
  let(:helper) { Class.new { include TimeHelper }.new }

  describe "#time_with_meridiem_abbr" do
    it "formats the time and wraps the meridiem in an <abbr>" do
      result = helper.time_with_meridiem_abbr("2024-01-01T14:30:00Z", "America/Denver")
      expect(result).to eq("07:30 <abbr title=\"ante meridiem\">AM</abbr>")
    end

    it "returns nil when the time or zone is blank" do
      expect(helper.time_with_meridiem_abbr(nil, "America/Denver")).to be_nil
      expect(helper.time_with_meridiem_abbr("2024-01-01T14:30:00Z", nil)).to be_nil
    end
  end

  describe "#meridiem_abbr" do
    it "wraps AM/PM in an <abbr> tag" do
      expect(helper.meridiem_abbr("9:05 AM")).to eq("9:05 <abbr title=\"ante meridiem\">AM</abbr>")
    end
  end
end
