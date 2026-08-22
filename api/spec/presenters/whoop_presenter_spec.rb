require "rails_helper"

RSpec.describe WhoopPresenter do
  def presenter(stats:, workouts: [ double("workout") ])
    described_class.new(stats: stats, workouts: workouts, time_zone: "America/Denver")
  end

  describe "scores" do
    it "rounds the sleep score" do
      expect(presenter(stats: { sleep: { score: { sleep_performance_percentage: 84.6 } } }).sleep_score).to eq(85)
    end

    it "rounds the recovery score" do
      expect(presenter(stats: { recovery: { score: { recovery_score: 67.4 } } }).recovery_score).to eq(67)
    end

    it "drops a trailing .0 from the strain score" do
      expect(presenter(stats: { physiological_cycle: { score: { strain: 12.0 } } }).strain_score).to eq("12")
      expect(presenter(stats: { physiological_cycle: { score: { strain: 12.46 } } }).strain_score).to eq("12.5")
    end
  end

  describe "#strain_label" do
    def label_for(strain, workouts: [ double("workout") ])
      presenter(stats: { physiological_cycle: { score: { strain: strain } } }, workouts: workouts).strain_label
    end

    it { expect(label_for(5)).to eq("Light") }
    it { expect(label_for(5, workouts: [])).to eq("Rest Day") }
    it { expect(label_for(12)).to eq("Moderate") }
    it { expect(label_for(16)).to eq("High") }
    it { expect(label_for(20)).to eq("All Out") }
    it { expect(label_for(0)).to eq("Nothing") }
  end

  describe "#sleep_label" do
    def label_for(score)
      presenter(stats: { sleep: { score: { sleep_performance_percentage: score } } }).sleep_label
    end

    it { expect(label_for(0)).to eq("None") }
    it { expect(label_for(50)).to eq("Poor") }
    it { expect(label_for(69)).to eq("Poor") }
    it { expect(label_for(70)).to eq("Sufficient") }
    it { expect(label_for(84)).to eq("Sufficient") }
    it { expect(label_for(85)).to eq("Optimal") }
    it { expect(label_for(90)).to eq("Optimal") }
  end

  describe "#recovery_label" do
    def label_for(score)
      presenter(stats: { recovery: { score: { recovery_score: score } } }).recovery_label
    end

    it { expect(label_for(0)).to eq("None") }
    it { expect(label_for(20)).to eq("Poor") }
    it { expect(label_for(33)).to eq("Poor") }
    it { expect(label_for(34)).to eq("Adequate") }
    it { expect(label_for(66)).to eq("Adequate") }
    it { expect(label_for(67)).to eq("Sufficient") }
    it { expect(label_for(80)).to eq("Sufficient") }
    it("has an easter egg at 69") { expect(label_for(69)).to eq("Nice.") }
  end

  describe "#recovery_icon" do
    def icon_for(score)
      presenter(stats: { recovery: { score: { recovery_score: score } } }).recovery_icon
    end

    it { expect(icon_for(20)).to eq("skull") }
    it { expect(icon_for(33)).to eq("skull") }
    it { expect(icon_for(34)).to eq("person-meditating") }
    it { expect(icon_for(80)).to eq("person-meditating") }
  end

  describe "#heading_label" do
    include ActiveSupport::Testing::TimeHelpers

    # Stop the clock at midday in the timezone of the presenter, thus "today" and "yesterday" are
    # always the same.
    around { |example| travel_to(Time.utc(2026, 6, 15, 18, 0, 0)) { example.run } }

    def label_for(sleep_end)
      presenter(stats: { sleep: { end: sleep_end } }).heading_label
    end

    it "labels metrics 'Latest' when there's no recorded wakeup" do
      expect(presenter(stats: {}).heading_label).to eq("Latest")
    end

    it "labels a wakeup from today 'Today’s'" do
      expect(label_for(Time.current.iso8601)).to eq("Today’s")
    end

    it "labels a wakeup from yesterday 'Yesterday’s'" do
      expect(label_for((Time.current - 1.day).iso8601)).to eq("Yesterday’s")
    end

    it "falls back to 'Latest' for older wakeups" do
      expect(label_for((Time.current - 5.days).iso8601)).to eq("Latest")
    end
  end

  describe "time zone fallback" do
    it "falls back to the default time zone when none is given" do
      p = described_class.new(stats: { sleep: { end: "2026-06-15T13:00:00Z" } }, time_zone: nil)
      expect(p.send(:last_wakeup_time).time_zone.name).to eq(TimeZoneResolver.default)
    end
  end
end
