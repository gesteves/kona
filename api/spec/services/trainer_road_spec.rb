require "rails_helper"

RSpec.describe TrainerRoad do
  subject(:service) { described_class.new("America/Denver") }

  describe "#determine_discipline" do
    it { expect(service.send(:determine_discipline, "Run - Easy")).to eq("Run") }
    it { expect(service.send(:determine_discipline, "Swim Endurance")).to eq("Swim") }
    it { expect(service.send(:determine_discipline, "Sweet Spot Base")).to eq("Bike") }
    it { expect(service.send(:determine_discipline, nil)).to be_nil }
  end

  describe "#human_readable_summary" do
    it "spells out durations up to 90 minutes" do
      expect(service.send(:human_readable_summary, "1:00", "Bike")).to eq("60-minute ride")
      expect(service.send(:human_readable_summary, "0:45", "Run")).to eq("45-minute run")
      expect(service.send(:human_readable_summary, "1:30", "Swim")).to eq("90-minute swim")
    end

    it "keeps the H:MM form past 90 minutes and says 'ride' for Bike" do
      expect(service.send(:human_readable_summary, "2:00", "Bike")).to eq("2:00 ride")
    end
  end

  describe "#parse_workout" do
    it "extracts duration, name, discipline, summary, and description" do
      event = double(summary: "1:00 - Petit", description: "Workout of the Week. Description: Sixty minutes of fun.")
      expect(service.send(:parse_workout, event)).to include(
        duration: "1:00",
        name: "Petit",
        discipline: "Bike",
        summary: "60-minute ride",
        description: "Sixty minutes of fun."
      )
    end

    it "returns nil for an event that isn't a workout" do
      expect(service.send(:parse_workout, double(summary: "Rest Day", description: ""))).to be_nil
    end
  end
end
