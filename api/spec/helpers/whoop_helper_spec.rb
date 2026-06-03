require "rails_helper"

RSpec.describe WhoopHelper do
  def whoop_helper(whoop:, workouts: [double("workout")])
    Class.new do
      include WhoopHelper
      include WorkoutsHelper
      include TimeHelper
    end.new.tap do |h|
      h.instance_variable_set(:@whoop, whoop)
      h.instance_variable_set(:@workouts, workouts)
      h.instance_variable_set(:@time_zone, "America/Denver")
    end
  end

  describe "scores" do
    it "rounds the sleep score" do
      helper = whoop_helper(whoop: { sleep: { score: { sleep_performance_percentage: 84.6 } } })
      expect(helper.whoop_sleep_score).to eq(85)
    end

    it "rounds the recovery score" do
      helper = whoop_helper(whoop: { recovery: { score: { recovery_score: 67.4 } } })
      expect(helper.whoop_recovery_score).to eq(67)
    end

    it "drops a trailing .0 from the strain score" do
      expect(whoop_helper(whoop: { physiological_cycle: { score: { strain: 12.0 } } }).whoop_strain_score).to eq("12")
      expect(whoop_helper(whoop: { physiological_cycle: { score: { strain: 12.46 } } }).whoop_strain_score).to eq("12.5")
    end
  end

  describe "#whoop_strain_label" do
    def label_for(strain, workouts: [double("workout")])
      whoop_helper(whoop: { physiological_cycle: { score: { strain: strain } } }, workouts: workouts).whoop_strain_label
    end

    it { expect(label_for(5)).to eq("Light") }
    it { expect(label_for(5, workouts: [])).to eq("Rest Day") }
    it { expect(label_for(12)).to eq("Moderate") }
    it { expect(label_for(16)).to eq("High") }
    it { expect(label_for(20)).to eq("All Out") }
    it { expect(label_for(0)).to eq("Nothing") }
  end

  describe "#whoop_sleep_label" do
    def label_for(score)
      whoop_helper(whoop: { sleep: { score: { sleep_performance_percentage: score } } }).whoop_sleep_label
    end

    it { expect(label_for(0)).to eq("None") }
    it { expect(label_for(50)).to eq("Poor") }
    it { expect(label_for(69)).to eq("Poor") }
    it { expect(label_for(70)).to eq("Sufficient") }
    it { expect(label_for(84)).to eq("Sufficient") }
    it { expect(label_for(85)).to eq("Optimal") }
    it { expect(label_for(90)).to eq("Optimal") }
  end

  describe "#whoop_recovery_label" do
    def label_for(score)
      whoop_helper(whoop: { recovery: { score: { recovery_score: score } } }).whoop_recovery_label
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

  describe "#whoop_recovery_icon" do
    def icon_for(score)
      whoop_helper(whoop: { recovery: { score: { recovery_score: score } } }).whoop_recovery_icon
    end

    it { expect(icon_for(20)).to eq("skull") }
    it { expect(icon_for(33)).to eq("skull") }
    it { expect(icon_for(34)).to eq("person-meditating") }
    it { expect(icon_for(80)).to eq("person-meditating") }
  end

  describe "#whoop_last_wakeup_time" do
    it "is nil when there's no recorded sleep end" do
      expect(whoop_helper(whoop: {}).whoop_last_wakeup_time).to be_nil
    end

    it "parses the sleep end into the location's timezone" do
      time = whoop_helper(whoop: { sleep: { end: "2026-06-15T13:00:00Z" } }).whoop_last_wakeup_time
      expect(time).to be_a(ActiveSupport::TimeWithZone)
      expect(time.time_zone.name).to eq("America/Denver")
    end
  end

  describe "#whoop_heading" do
    include ActiveSupport::Testing::TimeHelpers

    # Freeze to midday in the helper's timezone so "today"/"yesterday" are deterministic.
    around { |example| travel_to(Time.utc(2026, 6, 15, 18, 0, 0)) { example.run } }

    def heading_for(sleep_end)
      whoop_helper(whoop: { sleep: { end: sleep_end } }).whoop_heading
    end

    it "labels metrics 'Latest' when there's no recorded wakeup" do
      expect(whoop_helper(whoop: {}).whoop_heading).to include("Latest Metrics")
    end

    it "labels a wakeup from today 'Today’s'" do
      expect(heading_for(Time.current.iso8601)).to include("Today’s Metrics")
    end

    it "labels a wakeup from yesterday 'Yesterday’s'" do
      expect(heading_for((Time.current - 1.day).iso8601)).to include("Yesterday’s Metrics")
    end

    it "falls back to 'Latest' for older wakeups" do
      expect(heading_for((Time.current - 5.days).iso8601)).to include("Latest Metrics")
    end
  end
end
