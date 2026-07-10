require "rails_helper"

RSpec.describe ActivityDescription::Generator do
  subject(:generator) { described_class.new(intervals: intervals, trainer_road: trainer_road, lastfm: lastfm) }

  let(:intervals) do
    instance_double(
      Intervals,
      athlete_timezone: "America/Denver",
      temperature_unit: :celsius,
      activity_weather_summary: nil,
      activity_streams: nil,
      wellness: nil,
      update_activity!: nil
    )
  end
  let(:trainer_road) { instance_double(TrainerRoad, planned_workouts: []) }
  let(:lastfm) { instance_double(Lastfm, configured?: false) }

  let(:activity) do
    {
      id: "i1",
      type: "Ride",
      name: "Morning Ride",
      description: nil,
      start_date: "2026-07-09T13:30:00Z",
      start_date_local: "2026-07-09T07:30:00",
      moving_time: 3600,
      icu_average_watts: 200,
      trainer: true
    }
  end

  before do
    allow(intervals).to receive(:activity!).with("i1").and_return(activity)
    allow($redis).to receive(:set).and_return(true)
    allow($redis).to receive(:del)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
  end

  describe "the dedup lock" do
    it "takes and releases a per-activity Redis lock" do
      generator.generate!("i1")

      expect($redis).to have_received(:set).with("whoop:description_lock:i1", "1", nx: true, ex: 600)
      expect($redis).to have_received(:del).with("whoop:description_lock:i1")
    end

    it "skips (and doesn't release the other run's lock) when the lock is held" do
      allow($redis).to receive(:set).and_return(false)

      generator.generate!("i1")

      expect(intervals).not_to have_received(:activity!)
      expect($redis).not_to have_received(:del)
    end

    it "releases the lock even when the run raises" do
      allow(intervals).to receive(:activity!).and_raise("boom")

      expect { generator.generate!("i1") }.to raise_error("boom")
      expect($redis).to have_received(:del).with("whoop:description_lock:i1")
    end
  end

  describe "eligibility" do
    it "skips non-swim/bike/run activities without writing" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(type: "WeightTraining"))

      generator.generate!("i1")

      expect(intervals).not_to have_received(:update_activity!)
    end

    it "skips pool swims without writing" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(type: "Swim", pool_length: 25.0))

      generator.generate!("i1")

      expect(intervals).not_to have_received(:update_activity!)
    end
  end

  describe "composition and write" do
    it "writes the composed description, preserving user prose above the stat block" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(description: "Felt great.\n\n⚡️ Avg 190 W"))

      generator.generate!("i1", whoop_strain: 12.42)

      expect(intervals).to have_received(:update_activity!).with(
        "i1",
        description: "Felt great.\n\n⚡️ Avg 200 W\n🔥 12.4 Whoop Strain"
      )
    end

    it "skips the write when the composed description is empty" do
      bare = activity.merge(icu_average_watts: nil, name: nil)
      allow(intervals).to receive(:activity!).and_return(bare)

      generator.generate!("i1")

      expect(intervals).not_to have_received(:update_activity!)
    end
  end

  describe "the planned-workout headline" do
    before do
      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("key")
      allow(ActivityDescription::Llm).to receive(:planned_summary).and_return("2 hours of sweet spot")
      allow(ActivityDescription::Llm).to receive(:weather_sentence).and_return(nil)
    end

    it "summarizes the single case-sensitive name match" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(name: "Gibbs on the trainer"))
      allow(trainer_road).to receive(:planned_workouts).with(Date.new(2026, 7, 9))
        .and_return([{ name: "Gibbs", sport: "Cycling", description: "2x20 @ 90%" }])

      generator.generate!("i1")

      expect(ActivityDescription::Llm).to have_received(:planned_summary).with("2x20 @ 90%")
      expect(intervals).to have_received(:update_activity!).with("i1", description: a_string_starting_with("🗓️ 2 hours of sweet spot"))
    end

    it "is case-sensitive about the name match" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(name: "gibbs on the trainer"))
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([{ name: "Gibbs", sport: "Cycling", description: "2x20 @ 90%" }])

      generator.generate!("i1")

      expect(ActivityDescription::Llm).not_to have_received(:planned_summary)
    end

    it "refuses ambiguous (multiple) matches" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(name: "Gibbs +1"))
      allow(trainer_road).to receive(:planned_workouts).and_return(
        [
          { name: "Gibbs", sport: "Cycling", description: "a" },
          { name: "Gibbs +1", sport: "Cycling", description: "b" }
        ]
      )

      generator.generate!("i1")

      expect(ActivityDescription::Llm).not_to have_received(:planned_summary)
    end

    it "rejects sport-incompatible planned workouts" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(name: "Gibbs"))
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([{ name: "Gibbs", sport: "Running", description: "tempo" }])

      generator.generate!("i1")

      expect(ActivityDescription::Llm).not_to have_received(:planned_summary)
    end

    it "never offers a headline for swims" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(type: "OpenWaterSwim", name: "Ocean Swim", trainer: false))
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([{ name: "Ocean Swim", sport: "Swimming", description: "long swim" }])

      generator.generate!("i1")

      expect(ActivityDescription::Llm).not_to have_received(:planned_summary)
    end

    it "degrades to no headline when the TrainerRoad fetch fails" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(name: "Gibbs"))
      allow(trainer_road).to receive(:planned_workouts).and_raise("feed down")

      expect { generator.generate!("i1") }.not_to raise_error
      expect(ActivityDescription::Llm).not_to have_received(:planned_summary)
    end
  end

  describe "the weather line" do
    before do
      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("key")
      allow(ActivityDescription::Llm).to receive(:planned_summary).and_return(nil)
      allow(ActivityDescription::Llm).to receive(:weather_sentence).and_return({ emoji: "🌤️", sentence: "Mild and sunny" })
    end

    it "never fetches weather for indoor activities" do
      generator.generate!("i1") # trainer: true

      expect(intervals).not_to have_received(:activity_weather_summary)
    end

    it "treats virtual types and Zwift sources as indoor" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: nil, type: "VirtualRide"))
      generator.generate!("i1")

      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: nil, source: "ZWIFT"))
      generator.generate!("i1")

      expect(intervals).not_to have_received(:activity_weather_summary)
    end

    it "renders the LLM sentence with its emoji for outdoor activities" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: false))
      allow(intervals).to receive(:activity_weather_summary).with("i1").and_return("18°C, sunny")

      generator.generate!("i1")

      expect(intervals).to have_received(:update_activity!).with("i1", description: a_string_including("🌤️ Mild and sunny"))
    end

    it "loses only the weather line when that call fails" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: false))
      allow(intervals).to receive(:activity_weather_summary).and_return("18°C, sunny")
      allow(ActivityDescription::Llm).to receive(:weather_sentence).and_raise("timeout")

      generator.generate!("i1")

      expect(intervals).to have_received(:update_activity!).with("i1", description: "⚡️ Avg 200 W")
    end
  end

  describe "streams" do
    it "renders the heat line from the HSI stream (median over positive samples)" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(stream_types: %w[time heat_strain_index]))
      allow(intervals).to receive(:activity_streams).with("i1", types: %w[heat_strain_index time]).and_return(
        [{ type: "heat_strain_index", data: [0, 0, 1.0, 2.0, 3.0] }, { type: "time", data: [0, 1, 2, 3, 4] }]
      )

      generator.generate!("i1")

      expect(intervals).to have_received(:update_activity!).with("i1", description: a_string_including("🌡️ Max HSI 3.0 · Median HSI 2.0"))
    end

    it "renders the water-temperature line for open-water swims" do
      swim = activity.merge(type: "OpenWaterSwim", trainer: false, stream_types: %w[time temp], icu_average_watts: nil)
      allow(intervals).to receive(:activity!).and_return(swim)
      allow(intervals).to receive(:activity_streams).with("i1", types: %w[temp time]).and_return(
        [{ type: "temp", data: [15.0, 16.0, 17.0] }]
      )

      generator.generate!("i1")

      expect(intervals).to have_received(:update_activity!).with("i1", description: "💧 Water temperature 16 °C")
    end

    it "includes the heat-adaptation score from the wellness record" do
      allow(intervals).to receive(:wellness).with(Date.new(2026, 7, 9)).and_return({ CoreHeatAdaptationScore: 72 })

      generator.generate!("i1")

      expect(intervals).to have_received(:update_activity!).with("i1", description: a_string_including("🌡️ 72% heat adapted"))
    end
  end

  describe "the music line" do
    it "renders top artists from the activity's UTC window" do
      allow(lastfm).to receive(:configured?).and_return(true)
      start_time = Time.iso8601("2026-07-09T13:30:00Z")
      allow(lastfm).to receive(:played_songs_during).with(start_time, start_time + 3600).and_return(
        [{ artist: "Radiohead", name: "Weird Fishes", played_at: start_time, loved: false }]
      )

      generator.generate!("i1")

      expect(intervals).to have_received(:update_activity!).with("i1", description: a_string_including("🎧 Radiohead"))
    end

    it "loses only the music line when Last.fm fails" do
      allow(lastfm).to receive(:configured?).and_return(true)
      allow(lastfm).to receive(:played_songs_during).and_raise("lastfm down")

      generator.generate!("i1")

      expect(intervals).to have_received(:update_activity!).with("i1", description: "⚡️ Avg 200 W")
    end
  end

  describe "without an Anthropic key" do
    it "still composes the programmatic blocks" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: false, name: "Gibbs"))
      allow(intervals).to receive(:activity_weather_summary).and_return("18°C, sunny")
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([{ name: "Gibbs", sport: "Cycling", description: "2x20" }])

      generator.generate!("i1", whoop_strain: 10.0)

      expect(intervals).to have_received(:update_activity!).with("i1", description: "⚡️ Avg 200 W\n🔥 10.0 Whoop Strain")
    end
  end
end
