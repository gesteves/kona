require "rails_helper"

RSpec.describe MapTilesetJob do
  let(:library) { instance_double(TrackLibrary) }
  let(:uploader) { instance_double(MapboxTileset) }
  let(:record) { { "id" => "abc", "title" => "2026 Morning Run", "status" => "processing" } }
  let(:coordinates) { [ [ 10.0, 50.0 ], [ 11.0, 51.0 ] ] }

  before do
    allow(TrackLibrary).to receive(:new).and_return(library)
    allow(MapboxTileset).to receive(:new).and_return(uploader)
    allow(library).to receive(:find).with("abc").and_return(record)
    allow(library).to receive(:pending_coordinates).with("abc").and_return(coordinates)
    allow(library).to receive(:update)
    allow(library).to receive(:discard_pending)
    allow(uploader).to receive(:create_from_coordinates!).and_return("testuser.abc")
  end

  it "publishes the staged track and marks it ready" do
    described_class.new.perform("abc")

    expect(uploader).to have_received(:create_from_coordinates!)
      .with(id: "abc", name: "2026 Morning Run", coordinates: coordinates)
    expect(library).to have_received(:update).with("abc", hash_including(
      "status" => "ready", "tileset_id" => "testuser.abc", "source_layer" => "track"
    ))
  end

  it "releases the staged coordinates once they're on Mapbox" do
    described_class.new.perform("abc")

    expect(library).to have_received(:discard_pending).with("abc")
  end

  it "does nothing when the track was deleted before the job ran" do
    allow(library).to receive(:find).with("abc").and_return(nil)

    described_class.new.perform("abc")

    expect(uploader).not_to have_received(:create_from_coordinates!)
  end

  # A second attempt after a successful publish must not upload the data again.
  it "does nothing when the track is already published" do
    allow(library).to receive(:find).with("abc").and_return(record.merge("status" => "ready"))

    described_class.new.perform("abc")

    expect(uploader).not_to have_received(:create_from_coordinates!)
  end

  it "fails the track when its staged coordinates have expired" do
    allow(library).to receive(:pending_coordinates).with("abc").and_return(nil)

    described_class.new.perform("abc")

    expect(uploader).not_to have_received(:create_from_coordinates!)
    expect(library).to have_received(:update).with("abc", hash_including("status" => "failed"))
  end

  # ⚠️ It raises and does not record a failure, thus Sidekiq does the job again. A mark of "failed"
  # here would change the row from failed to processing to failed at each attempt.
  it "lets an upload error raise so the job retries" do
    allow(uploader).to receive(:create_from_coordinates!).and_raise("Mapbox failed to publish tileset")

    expect { described_class.new.perform("abc") }.to raise_error(/failed to publish/)
    expect(library).not_to have_received(:update).with("abc", hash_including("status" => "failed"))
  end

  describe "when Sidekiq gives up" do
    it "records the failure so the page stops saying it's processing" do
      described_class.sidekiq_retries_exhausted_block.call(
        { "args" => [ "abc" ] }, StandardError.new("Mapbox failed to publish tileset")
      )

      expect(library).to have_received(:update).with("abc", hash_including(
        "status" => "failed", "error" => "Mapbox failed to publish tileset"
      ))
    end
  end
end
