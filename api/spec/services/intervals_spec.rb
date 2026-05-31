require "rails_helper"

RSpec.describe Intervals do
  subject(:service) { described_class.new }

  before do
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  describe "#stats" do
    it "sums distances by discipline and counts only tri activities" do
      activities = [
        { "type" => "Swim",         "distance" => 1000 },
        { "type" => "OpenWaterSwim", "distance" => 1500 },
        { "type" => "Ride",         "distance" => 20000 },
        { "type" => "VirtualRide",  "distance" => 10000 },
        { "type" => "Run",          "distance" => 5000 },
        { "type" => "Walk",         "distance" => 3000 } # ignored
      ]
      allow(service).to receive(:get_json).and_return(activities)

      expect(service.stats).to eq(
        swim_distance: 2500, bike_distance: 30000, run_distance: 5000, total_activities: 5
      )
    end

    it "treats a missing distance as zero" do
      allow(service).to receive(:get_json).and_return([{ "type" => "Run" }])
      expect(service.stats[:run_distance]).to eq(0)
    end

    it "returns nil when activities can't be fetched" do
      allow(service).to receive(:get_json).and_return(nil)
      expect(service.stats).to be_nil
    end
  end
end
