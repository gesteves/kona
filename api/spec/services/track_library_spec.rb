require "rails_helper"

RSpec.describe TrackLibrary do
  subject(:library) { described_class.new }

  # Backed by a real Hash rather than per-call stubs, so ordering, overwrite, and the pruning
  # arithmetic are exercised for real. Same approach as spam_quarantine_spec.
  let(:store) { {} }
  let(:strings) { {} }

  before do
    allow($redis).to receive(:hset) { |_key, field, value| store[field] = value }
    allow($redis).to receive(:hget) { |_key, field| store[field] }
    allow($redis).to receive(:hgetall) { store.dup }
    allow($redis).to receive(:hlen) { store.size }
    allow($redis).to receive(:hdel) { |_key, *fields| fields.count { |f| store.delete(f) } }
    allow($redis).to receive(:setex) { |key, _ttl, value| strings[key] = value }
    allow($redis).to receive(:get) { |key| strings[key] }
    allow($redis).to receive(:del) { |key| strings.delete(key) ? 1 : 0 }
  end

  def track(title: "2026 Morning Run", coordinates: [ [ 10.0, 50.0 ], [ 11.0, 51.0 ] ])
    instance_double(GpxTrack,
      id: title.parameterize.tr("-", "_"),
      title: title,
      activity_type: "Running",
      activity_start: Time.utc(2026, 7, 25),
      bounds: { min_lon: 10.0, max_lon: 11.0, min_lat: 50.0, max_lat: 51.0 },
      start_coord: coordinates.first,
      end_coord: coordinates.last,
      start_icon: "pitch",
      coordinates: coordinates)
  end

  describe "#stage" do
    it "records the track as processing, with everything a render needs" do
      id = library.stage(track)
      record = library.find(id)

      expect(record).to include(
        "id" => id,
        "title" => "2026 Morning Run",
        "activity_type" => "Running",
        "status" => "processing",
        "start_coord" => [ 10.0, 50.0 ],
        "end_coord" => [ 11.0, 51.0 ]
      )
      expect(record["bounds"]).to eq("min_lon" => 10.0, "max_lon" => 11.0, "min_lat" => 50.0, "max_lat" => 51.0)
    end

    it "seeds the settings from the track's sport" do
      record = library.find(library.stage(track))

      expect(record["settings"]).to include("start_icon" => "pitch", "padding_top" => 50)
    end

    # ⚠️ The coordinates go in their own key, not the record: `app` and `worker` are separate fly
    # machines, and the index page loads every record in full.
    it "stages the coordinates separately, with an expiry" do
      id = library.stage(track)

      expect($redis).to have_received(:setex).with("maps:pending:#{id}", 3600, anything)
      expect(library.find(id)).not_to have_key("coordinates")
      expect(library.pending_coordinates(id)).to eq([ [ 10.0, 50.0 ], [ 11.0, 51.0 ] ])
    end

    it "reports nothing once the staged coordinates have expired" do
      id = library.stage(track)
      strings.clear

      expect(library.pending_coordinates(id)).to be_nil
    end
  end

  describe "#all" do
    it "is newest first" do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 1, 1))
      library.stage(track(title: "Older"))
      allow(Time).to receive(:now).and_return(Time.utc(2026, 6, 1))
      library.stage(track(title: "Newer"))

      expect(library.all.map { |r| r["title"] }).to eq([ "Newer", "Older" ])
    end

    it "drops an unparseable record rather than taking down the page" do
      library.stage(track)
      store["corrupt"] = "{not json"

      expect(library.all.length).to eq(1)
    end
  end

  describe "#update" do
    it "merges into the stored record" do
      id = library.stage(track)

      library.update(id, "status" => "ready", "tileset_id" => "user.abc")

      expect(library.find(id)).to include("status" => "ready", "tileset_id" => "user.abc", "title" => "2026 Morning Run")
    end

    it "reports a track that's already gone" do
      expect(library.update("nope", "status" => "ready")).to be_nil
    end
  end

  describe "#update_settings" do
    it "merges over the existing settings" do
      id = library.stage(track)

      library.update_settings(id, "padding_top" => "10", "track_color" => "#ffffff")
      settings = library.find(id)["settings"]

      expect(settings).to include("padding_top" => "10", "track_color" => "#ffffff", "start_icon" => "pitch")
    end

    # The keys come from a form, so anything that isn't a render setting must not reach the record.
    it "ignores keys that aren't settings" do
      id = library.stage(track)

      library.update_settings(id, "padding_top" => "10", "status" => "ready", "tileset_id" => "hijacked")

      expect(library.find(id)).to include("status" => "processing")
      expect(library.find(id)["settings"]).not_to have_key("tileset_id")
    end
  end

  describe "#statuses" do
    it "maps ids to statuses and nothing else" do
      id = library.stage(track)

      expect(library.statuses).to eq(id => "processing")
    end
  end

  describe "#delete" do
    it "removes the record and any staged coordinates" do
      id = library.stage(track)

      expect(library.delete(id)).to be(true)
      expect(library.find(id)).to be_nil
      expect(library.pending_coordinates(id)).to be_nil
    end

    it "reports a track that was already gone" do
      expect(library.delete("nope")).to be(false)
    end
  end

  describe "pruning" do
    it "trims oldest-first past MAX_ENTRIES" do
      stub_const("TrackLibrary::MAX_ENTRIES", 3)

      5.times do |i|
        allow(Time).to receive(:now).and_return(Time.utc(2026, 1, i + 1))
        library.stage(track(title: "Track #{i}"))
      end

      expect(library.all.map { |r| r["title"] }).to eq([ "Track 4", "Track 3", "Track 2" ])
    end
  end
end
