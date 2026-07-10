require "rails_helper"

RSpec.describe WhoopWebhookProcessor do
  subject(:processor) { described_class.new(whoop: whoop, intervals: intervals) }

  let(:whoop) { instance_double(Whoop) }
  let(:intervals) { instance_double(Intervals, athlete_timezone: timezone) }
  let(:timezone) { "America/Denver" }

  before do
    allow(intervals).to receive(:update_wellness!)
    allow(intervals).to receive(:update_activity!)
  end

  # A SCORED cycle whose end lands on the given local date in the athlete's timezone.
  def cycle_for(date, strain: 14.2, score_state: "SCORED")
    end_time = Time.find_zone!(timezone).parse("#{date} 06:00:00").utc.iso8601
    { id: 1, score_state: score_state, end: end_time, score: { strain: strain } }
  end

  def whoop_workout(start_time:, type: "Cycling", strain: 12.4)
    { id: "w1", activity_type: type, start_time: Time.iso8601(start_time), strain: strain }
  end

  describe "workout.updated" do
    let(:workout_start) { "2026-07-09T13:30:00Z" } # 07:30 local in Denver
    let(:activity) { { id: "i1", type: "Ride", start_date_local: "2026-07-09T07:31:00" } }

    before do
      allow(whoop).to receive(:get_workout).with("w1").and_return(whoop_workout(start_time: workout_start))
      allow(whoop).to receive(:raw_cycles).and_return([cycle_for(Date.new(2026, 7, 9))])
      allow(intervals).to receive(:activities!).and_return([activity])
    end

    it "refreshes the workout's local date, writes WhoopWorkoutStrain, and enqueues the description" do
      processor.process("workout.updated", "w1")

      expect(whoop).to have_received(:raw_cycles).with("2026-07-08", "2026-07-10")
      expect(intervals).to have_received(:update_wellness!).with("2026-07-09", WhoopStrain: 14.2)
      expect(intervals).to have_received(:activities!).with(oldest: Date.new(2026, 7, 8), newest: Date.new(2026, 7, 10))
      expect(intervals).to have_received(:update_activity!).with("i1", WhoopWorkoutStrain: 12.4)
      expect(ActivityDescriptionJob).to have_enqueued_sidekiq_job("i1", 12.4)
    end

    it "uses the workout's date in the athlete's timezone, not the UTC date" do
      # 23:30 local on the 8th is 05:30 UTC on the 9th — the local date must win.
      late_workout = whoop_workout(start_time: "2026-07-09T05:30:00Z")
      allow(whoop).to receive(:get_workout).and_return(late_workout)
      allow(intervals).to receive(:activities!).and_return([])
      allow(whoop).to receive(:raw_cycles).and_return([cycle_for(Date.new(2026, 7, 8))])

      processor.process("workout.updated", "w1")

      expect(whoop).to have_received(:raw_cycles).with("2026-07-07", "2026-07-09")
      expect(intervals).to have_received(:update_wellness!).with("2026-07-08", WhoopStrain: 14.2)
    end

    it "skips silently when the workout isn't found or scored" do
      allow(whoop).to receive(:get_workout).and_return(nil)

      processor.process("workout.updated", "w1")

      expect(intervals).not_to have_received(:update_wellness!)
      expect(intervals).not_to have_received(:update_activity!)
    end

    it "refreshes wellness but skips the activity write when nothing matches" do
      allow(intervals).to receive(:activities!).and_return([{ id: "i2", type: "Run", start_date_local: "2026-07-09T07:31:00" }])

      processor.process("workout.updated", "w1")

      expect(intervals).to have_received(:update_wellness!)
      expect(intervals).not_to have_received(:update_activity!)
      expect(ActivityDescriptionJob.jobs).to be_empty
    end

    it "writes strain but skips the description for non-swim/bike/run matches" do
      strength_workout = whoop_workout(start_time: workout_start, type: "Strength")
      allow(whoop).to receive(:get_workout).and_return(strength_workout)
      allow(intervals).to receive(:activities!).and_return([{ id: "i3", type: "WeightTraining", start_date_local: "2026-07-09T07:31:00" }])

      processor.process("workout.updated", "w1")

      expect(intervals).to have_received(:update_activity!).with("i3", WhoopWorkoutStrain: 12.4)
      expect(ActivityDescriptionJob.jobs).to be_empty
    end

    it "still enqueues the description when the strain write 422s (missing custom field)" do
      allow(intervals).to receive(:update_activity!).and_raise(ApplicationService::HttpError.new(422, "no field", "url"))
      allow(Rails.logger).to receive(:warn)

      processor.process("workout.updated", "w1")

      expect(ActivityDescriptionJob).to have_enqueued_sidekiq_job("i1", 12.4)
    end
  end

  describe "sleep.updated" do
    let(:sleep_data) do
      {
        id: "s1",
        cycle_id: 42,
        nap: false,
        end: "2026-01-02T04:30:00Z",
        timezone_offset: "-05:00",
        score_state: "SCORED",
        score: { sleep_performance_percentage: 88 }
      }
    end

    before do
      allow(whoop).to receive(:get_sleep).with("s1").and_return(sleep_data)
      allow(whoop).to receive(:raw_cycles).and_return([])
    end

    it "refreshes today and yesterday, and writes WhoopSleepPerformance for the offset end date" do
      today = Time.find_zone!(timezone).today

      processor.process("sleep.updated", "s1")

      expect(whoop).to have_received(:raw_cycles).with((today - 1).iso8601, (today + 1).iso8601)
      expect(whoop).to have_received(:raw_cycles).with((today - 2).iso8601, today.iso8601)
      # 04:30Z at -05:00 is 23:30 the previous day.
      expect(intervals).to have_received(:update_wellness!).with("2026-01-01", WhoopSleepPerformance: 88)
    end

    it "handles Z and colon-less positive offsets" do
      allow(whoop).to receive(:get_sleep).and_return(sleep_data.merge(timezone_offset: "Z"))
      processor.process("sleep.updated", "s1")
      expect(intervals).to have_received(:update_wellness!).with("2026-01-02", WhoopSleepPerformance: 88)

      allow(whoop).to receive(:get_sleep).and_return(sleep_data.merge(end: "2026-01-01T22:30:00Z", timezone_offset: "+0200"))
      processor.process("sleep.updated", "s1")
      # 22:30Z at +02:00 is 00:30 the next day.
      expect(intervals).to have_received(:update_wellness!).with("2026-01-02", WhoopSleepPerformance: 88).twice
    end

    it "skips naps" do
      allow(whoop).to receive(:get_sleep).and_return(sleep_data.merge(nap: true))

      processor.process("sleep.updated", "s1")

      expect(intervals).not_to have_received(:update_wellness!).with(anything, hash_including(:WhoopSleepPerformance))
    end

    it "skips sleeps without a performance percentage" do
      allow(whoop).to receive(:get_sleep).and_return(sleep_data.merge(score: {}))

      processor.process("sleep.updated", "s1")

      expect(intervals).not_to have_received(:update_wellness!).with(anything, hash_including(:WhoopSleepPerformance))
    end

    it "skips missing/unscored sleeps" do
      allow(whoop).to receive(:get_sleep).and_return(nil)

      expect { processor.process("sleep.updated", "s1") }.not_to raise_error
    end
  end

  describe "recovery.updated" do
    let(:sleep_data) do
      { id: "s1", cycle_id: 42, end: "2026-01-02T04:30:00Z", timezone_offset: "-05:00", score_state: "SCORED" }
    end
    let(:recovery) { { cycle_id: 42, score_state: "SCORED", score: { recovery_score: 82 } } }

    before do
      allow(whoop).to receive(:raw_cycles).and_return([])
      allow(whoop).to receive(:get_sleep).with("s1").and_return(sleep_data)
      allow(whoop).to receive(:get_recovery_for_cycle).with(42).and_return(recovery)
    end

    it "writes WhoopRecovery for the sleep's offset end date" do
      processor.process("recovery.updated", "s1")

      expect(intervals).to have_received(:update_wellness!).with("2026-01-01", WhoopRecovery: 82)
    end

    it "skips when the recovery isn't scored" do
      allow(whoop).to receive(:get_recovery_for_cycle).and_return(nil)

      processor.process("recovery.updated", "s1")

      expect(intervals).not_to have_received(:update_wellness!).with(anything, hash_including(:WhoopRecovery))
    end

    it "skips when the sleep isn't found" do
      allow(whoop).to receive(:get_sleep).and_return(nil)

      processor.process("recovery.updated", "s1")

      expect(whoop).not_to have_received(:get_recovery_for_cycle)
    end
  end

  describe "other event types" do
    before { allow(whoop).to receive(:raw_cycles).and_return([cycle_for(Time.find_zone!(timezone).today)]) }

    %w[workout.deleted sleep.deleted recovery.deleted].each do |event_type|
      it "refreshes only today's strain for #{event_type}" do
        today = Time.find_zone!(timezone).today

        processor.process(event_type, "x1")

        expect(whoop).to have_received(:raw_cycles).once
        expect(intervals).to have_received(:update_wellness!).with(today.iso8601, WhoopStrain: 14.2)
      end
    end
  end

  describe "daily strain refresh" do
    before { allow(whoop).to receive(:raw_cycles).and_return(cycles) }

    context "with an in-progress cycle (no end)" do
      let(:cycles) { [{ id: 1, score_state: "SCORED", end: nil, score: { strain: 9.9 } }] }

      it "counts it as today" do
        today = Time.find_zone!(timezone).today

        processor.process("recovery.deleted", "x1")

        expect(intervals).to have_received(:update_wellness!).with(today.iso8601, WhoopStrain: 9.9)
      end
    end

    context "with only unscored cycles" do
      let(:cycles) { [cycle_for(Time.find_zone!(timezone).today, score_state: "PENDING_SCORE")] }

      it "leaves wellness untouched" do
        processor.process("recovery.deleted", "x1")

        expect(intervals).not_to have_received(:update_wellness!)
      end
    end

    context "with no cycle for the date" do
      let(:cycles) { [] }

      it "leaves wellness untouched" do
        processor.process("recovery.deleted", "x1")

        expect(intervals).not_to have_received(:update_wellness!)
      end
    end
  end

  describe "the missing-custom-field guard" do
    before { allow(whoop).to receive(:raw_cycles).and_return([cycle_for(Time.find_zone!(timezone).today)]) }

    it "warns and continues on a 422" do
      allow(intervals).to receive(:update_wellness!).and_raise(ApplicationService::HttpError.new(422, "no such field", "url"))
      allow(Rails.logger).to receive(:warn)

      expect { processor.process("recovery.deleted", "x1") }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/Create the custom field/)
    end

    it "propagates other HTTP errors so the job can retry" do
      allow(intervals).to receive(:update_wellness!).and_raise(ApplicationService::HttpError.new(500, "boom", "url"))

      expect { processor.process("recovery.deleted", "x1") }.to raise_error(ApplicationService::HttpError)
    end
  end

  describe "offset parsing" do
    it "raises on an unrecognized offset" do
      allow(whoop).to receive(:raw_cycles).and_return([])
      allow(whoop).to receive(:get_sleep).and_return(
        { id: "s1", cycle_id: 1, nap: false, end: "2026-01-02T04:30:00Z", timezone_offset: "EST", score_state: "SCORED", score: { sleep_performance_percentage: 90 } }
      )

      expect { processor.process("sleep.updated", "s1") }.to raise_error(ArgumentError, /Unrecognized fixed timezone offset/)
    end
  end
end
