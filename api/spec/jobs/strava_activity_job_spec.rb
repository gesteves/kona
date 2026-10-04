require "rails_helper"

RSpec.describe StravaActivityJob do
  let(:intervals) { instance_double(Intervals) }
  # 2026-07-09 at 14:00 UTC.
  let(:event_time) { Time.utc(2026, 7, 9, 14).to_i }

  before do
    allow(Intervals).to receive(:new).and_return(intervals)
    allow_any_instance_of(Location).to receive(:time_zone).and_return("America/Denver")
  end

  it "finds the Intervals.icu activity by its Strava id and adds its description job" do
    allow(intervals).to receive(:activities!).and_return(
      [ { id: "i1", strava_id: "555" }, { id: "i2", strava_id: "123" } ]
    )

    described_class.new.perform("123", event_time)

    expect(intervals).to have_received(:activities!).with(oldest: Date.new(2026, 7, 7), newest: Date.new(2026, 7, 10))
    expect(ActivityDescriptionJob).to have_enqueued_sidekiq_job("i2")
  end

  it "raises ActivityNotSynced while Intervals.icu does not have the activity" do
    allow(intervals).to receive(:activities!).and_return([ { id: "i1", strava_id: "555" } ])

    expect { described_class.new.perform("123", event_time) }.to raise_error(described_class::ActivityNotSynced)
    expect(ActivityDescriptionJob.jobs).to be_empty
  end

  # ⚠️ An activity that never reaches Intervals.icu must not retry for the 24 hours of ApplicationJob.
  it "tries again after 1, 2, 3, 4, and 5 minutes, then stops out of the Dead set" do
    options = described_class.get_sidekiq_options
    expect(options).to include("retry" => 5, "retry_for" => nil, "dead" => false)

    delays = (0..4).map { |count| described_class.sidekiq_retry_in_block.call(count, described_class::ActivityNotSynced.new) }
    expect(delays).to eq([ 1, 2, 3, 4, 5 ].map(&:minutes))
    expect(described_class.sidekiq_retry_in_block.call(0, RuntimeError.new)).to be_nil
  end
end
