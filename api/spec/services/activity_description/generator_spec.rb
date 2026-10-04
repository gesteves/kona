require "rails_helper"

RSpec.describe ActivityDescription::Generator do
  subject(:generator) do
    described_class.new(intervals: intervals, strava: strava, whoop: whoop, location: location, trainer_road: trainer_road)
  end

  let(:intervals) do
    instance_double(
      Intervals,
      temperature_unit: :celsius,
      activity_streams: nil,
      wellness: nil,
      update_activity!: nil
    )
  end
  let(:strava) do
    instance_double(Strava, connected?: true, activity: { name: "Morning Ride", description: nil }, update_activity!: nil)
  end
  let(:whoop) { instance_double(Whoop, valid_credentials?: true, connected?: true, workouts_between: []) }
  let(:location) { instance_double(Location, time_zone: "America/Denver") }
  let(:trainer_road) { instance_double(TrainerRoad, planned_workouts: []) }

  # A scored Whoop workout that matches the activity below.
  def whoop_workout(strain)
    { id: "w1", activity_type: "Cycling", start_time: Time.iso8601("2026-07-09T13:30:00Z"), strain: strain }
  end

  let(:activity) do
    {
      id: "i1",
      strava_id: "s1",
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

      expect($redis).to have_received(:set).with("activity:description_lock:i1", "1", nx: true, ex: 600)
      expect($redis).to have_received(:del).with("activity:description_lock:i1")
    end

    # ⚠️ The second of two close webhooks can be the run with the Whoop strain, thus the job runs it
    # again later and does not drop it.
    it "gives :busy (and doesn't release the other run's lock) when the lock is held" do
      allow($redis).to receive(:set).and_return(false)
      allow($redis).to receive(:get).with("activity:description_lock:i1").and_return("another-job")

      expect(generator.generate!("i1", lock_token: "job-1")).to eq(:busy)

      expect(intervals).not_to have_received(:activity!)
      expect($redis).not_to have_received(:del)
    end

    # ⚠️ A process that dies leaves the lock, and the retry comes some seconds later. Without this
    # the retry would read its own lock as another run.
    it "enters the lock that its own earlier attempt left" do
      allow($redis).to receive(:set).and_return(false)
      allow($redis).to receive(:get).with("activity:description_lock:i1").and_return("job-1")

      generator.generate!("i1", lock_token: "job-1")

      expect(intervals).to have_received(:activity!)
      expect($redis).to have_received(:del).with("activity:description_lock:i1")
    end

    it "releases the lock even when the run raises" do
      allow(intervals).to receive(:activity!).and_raise("boom")

      expect { generator.generate!("i1") }.to raise_error("boom")
      expect($redis).to have_received(:del).with("activity:description_lock:i1")
    end
  end

  describe "eligibility" do
    it "skips non-swim/bike/run activities without writing" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(type: "WeightTraining"))

      generator.generate!("i1")

      expect(strava).not_to have_received(:update_activity!)
    end

    it "skips pool swims without writing" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(type: "Swim", pool_length: 25.0))

      generator.generate!("i1")

      expect(strava).not_to have_received(:update_activity!)
    end
  end

  describe "composition and write" do
    # The owner writes in Strava, thus the words above the stat block come from the Strava copy.
    it "writes the composed description, preserving user prose above the stat block" do
      allow(strava).to receive(:activity).with("s1").and_return({ name: "Morning Ride", description: "Felt great.\n\n⚡️ Avg 190 W" })
      allow(whoop).to receive(:workouts_between).and_return([ whoop_workout(12.42) ])

      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with(
        "s1",
        description: "Felt great.\n\n⚡️ Avg 200 W\n🔥 12.4 Whoop Strain"
      )
    end

    it "skips the write when there's nothing to change" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(icu_average_watts: nil))
      allow(strava).to receive(:activity).and_return({ name: nil, description: nil })

      generator.generate!("i1")

      expect(strava).not_to have_received(:update_activity!)
    end

    it "tidies a Rouvy name alongside the description" do
      allow(strava).to receive(:activity).and_return({ name: "ROUVY - Klahane Ridge - 2026-08-12", description: nil })

      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with(
        "s1",
        name: "Rouvy - Klahane Ridge",
        description: "⚡️ Avg 200 W"
      )
    end

    it "writes the name alone when the composed description is empty" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(icu_average_watts: nil))
      allow(strava).to receive(:activity).and_return({ name: "ROUVY - Klahane Ridge - 2026-08-12", description: nil })

      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with("s1", name: "Rouvy - Klahane Ridge")
    end
  end

  describe "the Strava write" do
    it "never writes the name or the description to Intervals.icu" do
      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with("s1", description: "⚡️ Avg 200 W")
      expect(intervals).not_to have_received(:update_activity!)
    end

    # The Strava webhook starts a new run when the copy arrives.
    it "skips, before any read of Strava, an activity with no Strava id yet" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(strava_id: nil))

      generator.generate!("i1")

      expect(strava).not_to have_received(:activity)
      expect(strava).not_to have_received(:update_activity!)
    end

    it "skips when Strava is not connected" do
      allow(strava).to receive(:connected?).and_return(false)

      generator.generate!("i1")

      expect(strava).not_to have_received(:update_activity!)
    end
  end

  describe "the Whoop strain" do
    it "gets the strain of the matching workout from Whoop, in a window around the activity" do
      allow(whoop).to receive(:workouts_between).and_return([ whoop_workout(14.2) ])

      generator.generate!("i1")

      expect(whoop).to have_received(:workouts_between).with(Time.utc(2026, 7, 9, 12, 30), Time.utc(2026, 7, 9, 15, 30))
      expect(strava).to have_received(:update_activity!).with("s1", description: "⚡️ Avg 200 W\n🔥 14.2 Whoop Strain")
    end

    it "gives no 🔥 line when no workout matches" do
      allow(whoop).to receive(:workouts_between).and_return([ whoop_workout(14.2).merge(activity_type: "Running") ])

      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with("s1", description: "⚡️ Avg 200 W")
    end

    it "loses only the 🔥 line when Whoop fails" do
      allow(whoop).to receive(:workouts_between).and_raise("Whoop down")

      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with("s1", description: "⚡️ Avg 200 W")
    end

    it "asks Whoop nothing for a swim, or without a Whoop connection" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(type: "OpenWaterSwim"))
      generator.generate!("i1")

      allow(intervals).to receive(:activity!).and_return(activity)
      allow(whoop).to receive(:connected?).and_return(false)
      generator.generate!("i1")

      expect(whoop).not_to have_received(:workouts_between)
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
        .and_return([ { name: "Gibbs", sport: "Cycling", description: "2x20 @ 90%" } ])

      generator.generate!("i1")

      expect(ActivityDescription::Llm).to have_received(:planned_summary).with("2x20 @ 90%")
      expect(strava).to have_received(:update_activity!).with("s1", description: a_string_starting_with("🗓️ 2 hours of sweet spot"))
    end

    it "skips the headline when the activity is shorter than the workout" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(name: "Gibbs on the trainer", moving_time: 3600))
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([ { name: "Gibbs", sport: "Cycling", description: "2x20 @ 90%", duration_minutes: 90 } ])

      generator.generate!("i1")

      expect(ActivityDescription::Llm).not_to have_received(:planned_summary)
    end

    it "keeps the headline when the activity stops in the 5-minute cooldown buffer" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(name: "Gibbs on the trainer", moving_time: 3600))
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([ { name: "Gibbs", sport: "Cycling", description: "2x20 @ 90%", duration_minutes: 65 } ])

      generator.generate!("i1")

      expect(ActivityDescription::Llm).to have_received(:planned_summary).with("2x20 @ 90%")
    end

    it "keeps the headline when the activity is longer than the workout" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(name: "Gibbs on the trainer", moving_time: 7200))
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([ { name: "Gibbs", sport: "Cycling", description: "2x20 @ 90%", duration_minutes: 60 } ])

      generator.generate!("i1")

      expect(ActivityDescription::Llm).to have_received(:planned_summary).with("2x20 @ 90%")
    end

    it "is case-sensitive about the name match" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(name: "gibbs on the trainer"))
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([ { name: "Gibbs", sport: "Cycling", description: "2x20 @ 90%" } ])

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
        .and_return([ { name: "Gibbs", sport: "Running", description: "tempo" } ])

      generator.generate!("i1")

      expect(ActivityDescription::Llm).not_to have_received(:planned_summary)
    end

    it "never offers a headline for swims" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(type: "OpenWaterSwim", name: "Ocean Swim", trainer: false))
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([ { name: "Ocean Swim", sport: "Swimming", description: "long swim" } ])

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
    let(:streams) do
      [
        { type: "time", data: (0..30).map { |minute| minute * 60 } },
        { type: "latlng", data: (0..30).map { |minute| 40.0 + (minute * 0.001) }, data2: Array.new(31, -105.0) }
      ]
    end
    let(:hours) do
      (13..15).map do |hour|
        { forecastStart: "2026-07-09T#{hour}:00:00Z", temperature: 18.0, temperatureApparent: 18.0, windSpeed: 5.0,
          windDirection: 180, conditionCode: "Clear", daylight: true }
      end
    end

    before do
      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("key")
      allow(ActivityDescription::Llm).to receive(:planned_summary).and_return(nil)
      allow(ActivityDescription::Llm).to receive(:weather_sentence).and_return("Clear and mild")
      allow(intervals).to receive(:activity_streams).with("i1", types: %w[latlng time]).and_return(streams)
      allow(WeatherKit).to receive(:hourly).and_return(hours)
    end

    it "never fetches weather for indoor activities" do
      generator.generate!("i1") # trainer: true

      expect(WeatherKit).not_to have_received(:hourly)
    end

    it "treats virtual types and Zwift sources as indoor" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: nil, type: "VirtualRide"))
      generator.generate!("i1")

      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: nil, source: "ZWIFT"))
      generator.generate!("i1")

      expect(WeatherKit).not_to have_received(:hourly)
    end

    it "renders the emoji of the WeatherKit condition and the LLM sentence for outdoor activities" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: false))

      generator.generate!("i1")

      expect(ActivityDescription::Llm).to have_received(:weather_sentence).with(hash_including(condition: "Clear"))
      expect(strava).to have_received(:update_activity!).with("s1", description: a_string_including("☀️ Clear and mild"))
    end

    it "gives no headwind for a swim" do
      swim = activity.merge(type: "OpenWaterSwim", trainer: false, icu_average_watts: nil)
      allow(intervals).to receive(:activity!).and_return(swim)

      generator.generate!("i1")

      expect(ActivityDescription::Llm).to have_received(:weather_sentence).with(hash_excluding(:headwind_percent))
    end

    it "loses only the weather line when that call fails" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: false))
      allow(ActivityDescription::Llm).to receive(:weather_sentence).and_raise("timeout")

      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with("s1", description: "⚡️ Avg 200 W")
    end

    it "loses only the weather line when WeatherKit has no data" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: false))
      allow(WeatherKit).to receive(:hourly).and_return(nil)

      generator.generate!("i1")

      expect(ActivityDescription::Llm).not_to have_received(:weather_sentence)
      expect(strava).to have_received(:update_activity!).with("s1", description: "⚡️ Avg 200 W")
    end
  end

  describe "streams" do
    it "renders the water-temperature line for open-water swims" do
      swim = activity.merge(type: "OpenWaterSwim", trainer: false, stream_types: %w[time temp], icu_average_watts: nil)
      allow(intervals).to receive(:activity!).and_return(swim)
      allow(intervals).to receive(:activity_streams).with("i1", types: %w[temp time]).and_return(
        [ { type: "temp", data: [ 15.0, 16.0, 17.0 ] } ]
      )

      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with("s1", description: "💧 Water temperature 16 °C")
    end

    it "includes the heat-adaptation score from the wellness record" do
      allow(intervals).to receive(:wellness).with(Date.new(2026, 7, 9)).and_return({ CoreHeatAdaptationScore: 72 })

      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with("s1", description: a_string_including("🌡️ 72% heat adapted"))
    end
  end

  describe "without an Anthropic key" do
    it "still composes the programmatic blocks" do
      allow(intervals).to receive(:activity!).and_return(activity.merge(trainer: false, name: "Gibbs"))
      allow(trainer_road).to receive(:planned_workouts)
        .and_return([ { name: "Gibbs", sport: "Cycling", description: "2x20" } ])

      allow(whoop).to receive(:workouts_between).and_return([ whoop_workout(10.0) ])

      generator.generate!("i1")

      expect(strava).to have_received(:update_activity!).with("s1", description: "⚡️ Avg 200 W\n🔥 10.0 Whoop Strain")
    end
  end
end
