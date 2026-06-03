require "rails_helper"

RSpec.describe UnitsHelper do
  subject(:helper) { Class.new { include UnitsHelper }.new }

  describe "unit conversions" do
    it { expect(helper.celsius_to_fahrenheit(0)).to eq(32) }
    it { expect(helper.celsius_to_fahrenheit(100)).to eq(212) }
    it { expect(helper.meters_to_feet(1)).to be_within(0.001).of(3.28084) }
    it { expect(helper.kilometers_to_miles(1)).to be_within(0.001).of(0.621371) }
    it { expect(helper.kph_to_knots(1)).to be_within(0.001).of(0.539957) }
    it { expect(helper.millimeters_to_inches(25.4)).to be_within(0.001).of(1.0) }
    it { expect(helper.meters_to_miles(1609.344)).to be_within(0.01).of(1.0) }
    it { expect(helper.meters_to_yards(1)).to be_within(0.001).of(1.09361) }
  end

  describe "#distance" do
    it "uses meters under 1 km (metric)" do
      expect(helper.distance(500, units: "metric")).to match(/\bmeters?\b/)
    end

    it "uses kilometers at/over 1 km (metric)" do
      expect(helper.distance(5000, units: "metric")).to match(/\bkilometers?\b/)
    end

    it "uses yards under a mile (imperial)" do
      expect(helper.distance(100, units: "imperial")).to match(/\byards?\b/)
    end

    it "uses miles over a mile (imperial)" do
      expect(helper.distance(5000, units: "imperial")).to match(/\bmiles?\b/)
    end

    it "splits the value and the unit" do
      expect(helper.distance_value(5000, units: "metric")).to eq("5")
      expect(helper.distance_unit(5000, units: "metric")).to eq("kilometers")
    end

    it "defaults to SI (metric) units" do
      expect(helper.distance(5000)).to match(/\bkilometers?\b/)
      expect(helper.distance(500)).to match(/\bmeters?\b/)
    end

    it "switches to kilometers at exactly 1 km, and stays in meters just below" do
      expect(helper.meters_to_metric_units(1000)).to eq([1.0, { unit: "kilometer" }])
      expect(helper.meters_to_metric_units(999).last).to eq(unit: "meters")
    end
  end

  describe "#determine_precision" do
    it "gives more decimals for small numbers and none for large ones" do
      expect(helper.determine_precision(5)).to eq(1)
      expect(helper.determine_precision(5000)).to eq(0)
    end
  end
end
