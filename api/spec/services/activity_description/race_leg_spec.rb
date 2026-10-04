require "rails_helper"

RSpec.describe ActivityDescription::RaceLeg do
  let(:race) { "Ironman 70.3 Washington Tri-Cities" }

  def leg(id, type, start, external_id: "24436841087")
    { id: id, type: type, start_date: start, external_id: external_id }
  end

  def name_of(activity, day) = described_class.find(activity, day_activities: day, race_name: race)&.name

  def names(day)
    day.sort_by { |activity| activity[:start_date] }.map { |activity| name_of(activity, day) }
  end

  def named(*labels) = labels.map { |label| label && "#{race} – #{label}" }

  describe "one multisport file" do
    # The legs of the Tri-Cities race day, as Intervals.icu gives them.
    let(:full) do
      [
        leg("i5", "Run", "2026-09-20T17:47:11Z"),
        leg("i1", "OpenWaterSwim", "2026-09-20T14:26:00Z"),
        leg("i2", "Transition", "2026-09-20T14:53:38Z"),
        leg("i3", "Ride", "2026-09-20T15:02:39Z"),
        leg("i4", "Transition", "2026-09-20T17:41:16Z")
      ]
    end

    it "names the five legs of a triathlon, in the order of the start times" do
      expect(names(full)).to eq(named("Swim", "T1", "Bike", "T2", "Run"))
    end

    it "names the transition after the bike T2 when the swim was cancelled" do
      expect(names(full.reject { |activity| %w[i1 i2].include?(activity[:id]) })).to eq(named("Bike", "T2", "Run"))
    end

    it "names a transition with no leg before it by the leg after it" do
      day = [ leg("t", "Transition", "2026-09-20T14:00:00Z"), leg("b", "Ride", "2026-09-20T14:05:00Z") ]

      expect(name_of(day.first, day)).to eq("#{race} – T1")
    end

    it "needs no other run, thus it gives no partner" do
      expect(described_class.find(full.first, day_activities: full, race_name: race).partner_id).to be_nil
    end
  end

  # The swim was cancelled, and the bike computer and the watch each made a file.
  describe "separate files" do
    let(:day) do
      [
        leg("warmup", "Run", "2026-09-20T13:00:00Z", external_id: "w1"),
        leg("spin", "Ride", "2026-09-20T13:20:00Z", external_id: "b1"),
        leg("bike", "Ride", "2026-09-20T15:00:00Z", external_id: "b2"),
        leg("run", "Run", "2026-09-20T17:45:00Z", external_id: "w2"),
        leg("cooldown", "Run", "2026-09-20T19:30:00Z", external_id: "w3")
      ]
    end

    it "names the last ride before the first run after a ride, and that run" do
      expect(names(day)).to eq(named(nil, nil, "Bike", "Run", nil))
    end

    it "gives each leg the other one as its partner" do
      expect(described_class.find(day[2], day_activities: day, race_name: race).partner_id).to eq("run")
      expect(described_class.find(day[3], day_activities: day, race_name: race).partner_id).to eq("bike")
    end

    # The bike computer can upload first. The run then queues the bike again.
    it "gives the bike no name while the run is not there yet" do
      expect(name_of(day[2], day.first(3))).to be_nil
    end
  end

  it "gives nil for an activity that is not a leg" do
    day = [ leg("x", "Run", "2026-09-20T20:00:00Z", external_id: "other") ]

    expect(name_of(day.first, day)).to be_nil
  end

  it "gives nil with no race" do
    day = [ leg("b", "Ride", "2026-09-20T15:00:00Z", external_id: "b"), leg("r", "Run", "2026-09-20T17:00:00Z", external_id: "r") ]

    expect(described_class.find(day.first, day_activities: day, race_name: nil)).to be_nil
  end
end
