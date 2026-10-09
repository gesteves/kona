require "rails_helper"

RSpec.describe RaceTrackJob do
  let(:intervals) { instance_double(Intervals) }
  let(:library) { instance_double(TrackLibrary, find: nil, stage: "track_id") }
  let(:gpx) do
    <<~XML
      <gpx><trk><name>Morning Ride</name><trkseg>
        <trkpt lat="37.8" lon="-122.4"><time>2026-07-09T13:30:00Z</time></trkpt>
        <trkpt lat="37.9" lon="-122.5"/>
      </trkseg></trk></gpx>
    XML
  end

  before do
    allow(Intervals).to receive(:new).and_return(intervals)
    allow(TrackLibrary).to receive(:new).and_return(library)
    allow(intervals).to receive(:activity_gpx).with("i1").and_return(gpx)
  end

  it "stages the track with the name of the leg and publishes it" do
    described_class.new.perform("i1", "Golden Gate Tri – Bike", "Cycling")

    expect(library).to have_received(:stage).with(
      an_object_having_attributes(title: "2026 Golden Gate Tri – Bike", start_icon: "bicycle-share")
    )
    expect(MapTilesetJob).to have_enqueued_sidekiq_job("track_id")
  end

  # The owner can upload the same race by hand, and can change its render settings.
  it "keeps a track that exists" do
    allow(library).to receive(:find).and_return({ "id" => "x" })

    described_class.new.perform("i1", "Golden Gate Tri – Bike", "Cycling")

    expect(library).not_to have_received(:stage)
    expect(MapTilesetJob.jobs).to be_empty
  end

  it "raises when Intervals.icu gives no GPX, thus the job tries again" do
    allow(intervals).to receive(:activity_gpx).and_return(nil)

    expect { described_class.new.perform("i1", "Golden Gate Tri – Bike", "Cycling") }
      .to raise_error(described_class::GpxUnavailable)
  end

  # Another attempt gives the same result.
  it "does not raise for a GPX that it cannot read" do
    allow(intervals).to receive(:activity_gpx).and_return("<gpx><trk><name>x</name></trk></gpx>")

    expect { described_class.new.perform("i1", "Golden Gate Tri – Bike", "Cycling") }.not_to raise_error
    expect(library).not_to have_received(:stage)
  end
end
