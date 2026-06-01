require "rails_helper"

RSpec.describe IconsHelper do
  subject(:helper) do
    Class.new { include IconsHelper }.new.tap do |h|
      # Echo the requested icon id so we can assert which clock face is chosen, without Font Awesome.
      allow(h).to receive(:icon_svg) { |_family, _style, id| id }
    end
  end

  describe "#icon_svg" do
    subject(:helper) { Class.new { include IconsHelper }.new }

    it "marks the icon decorative (aria-hidden, non-focusable) for assistive tech" do
      allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg viewBox="0 0 1 1"><path/></svg>')
      expect(helper.icon_svg("classic", "light", "eye"))
        .to eq('<svg aria-hidden="true" focusable="false" viewBox="0 0 1 1"><path/></svg>')
    end

    it "returns nil when the icon is unavailable" do
      allow_any_instance_of(FontAwesome).to receive(:svg).and_return(nil)
      expect(helper.icon_svg("classic", "light", "nope")).to be_nil
    end
  end

  describe "#clock_icon_svg" do
    def icon_at(time)
      helper.clock_icon_svg(Time.parse(time))
    end

    it "rounds down to the hour before quarter past" do
      expect(icon_at("2024-01-01 15:05")).to eq("clock-three")
    end

    it "rounds to half past between :15 and :45" do
      expect(icon_at("2024-01-01 15:20")).to eq("clock-three-thirty")
    end

    it "rounds up to the next hour at/after :45" do
      expect(icon_at("2024-01-01 14:50")).to eq("clock-three")
    end

    it "uses 'clock' for four o'clock (there's no clock-four icon)" do
      expect(icon_at("2024-01-01 16:00")).to eq("clock")
    end

    it "wraps midnight/noon to twelve" do
      expect(icon_at("2024-01-01 00:00")).to eq("clock-twelve")
      expect(icon_at("2024-01-01 11:50")).to eq("clock-twelve")
    end
  end
end
