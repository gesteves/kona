require "rails_helper"

RSpec.describe GpxTrack do
  def fixture = Rails.root.join("spec/fixtures/track.gpx")

  def build(xml)
    described_class.new(StringIO.new(xml))
  end

  subject(:track) { File.open(fixture) { |io| described_class.new(io) } }

  describe "reading the document" do
    it "takes the name and type from the track, not the metadata" do
      expect(track.title).to include("Ironman 70.3 Boise")
      expect(track.title).not_to include("Not the track name")
      expect(track.activity_type).to eq("Road Biking")
    end

    it "dates the activity from its first trackpoint" do
      expect(track.activity_start).to eq(Time.utc(2026, 7, 25, 13, 32, 14))
    end

    it "collects every trackpoint as [lon, lat]" do
      expect(track.coordinates.length).to eq(3)
      expect(track.start_coord).to eq([ -116.055526, 43.52207 ])
      expect(track.end_coord).to eq([ -116.206274, 43.607905 ])
    end

    # Garmin writes 26 significant digits for each value. That makes the Redis payload and the Mapbox
    # upload three times larger, for an accuracy that is smaller than one pixel on the map.
    it "rounds coordinates to six decimal places" do
      expect(track.coordinates.flatten).to all(satisfy { |value| value.to_s.split(".").last.length <= 6 })
    end

    it "reads a track with no namespace declared" do
      parsed = build(<<~XML)
        <gpx><trk><name>Bare</name><type>running</type><trkseg>
          <trkpt lat="1.0" lon="2.0"></trkpt>
        </trkseg></trk></gpx>
      XML

      expect(parsed.activity_type).to eq("Running")
      expect(parsed.coordinates.length).to eq(1)
    end

    it "reads self-closing trackpoints" do
      parsed = build('<gpx><trk><name>Bare</name><trkseg><trkpt lat="1.0" lon="2.0"/></trkseg></trk></gpx>')

      expect(parsed.coordinates.length).to eq(1)
    end
  end

  describe "failure" do
    it "refuses a document with no track points" do
      expect { build("<gpx><trk><name>Empty</name></trk></gpx>") }
        .to raise_error(described_class::ParseError, /No track points/)
    end

    it "refuses something that isn't XML at all" do
      expect { build("this is not a gpx file") }.to raise_error(described_class::ParseError)
    end
  end

  describe "#title" do
    def titled(name, type: "running", time: "2026-07-25T13:32:14.000Z")
      build(<<~XML).title
        <gpx><trk><name>#{name}</name><type>#{type}</type><trkseg>
          <trkpt lat="1.0" lon="2.0"><time>#{time}</time></trkpt>
        </trkseg></trk></gpx>
      XML
    end

    it "prefixes the year the activity started" do
      expect(titled("Boise Marathon")).to eq("2026 Boise Marathon")
    end

    it "moves a year already in the name to the front rather than repeating it" do
      expect(titled("Boise 2026 Marathon")).to eq("2026 Boise Marathon")
    end

    it "appends the activity type when the name names no sport" do
      expect(titled("Wednesday Nighter", type: "cycling")).to eq("2026 Wednesday Nighter - Cycling")
    end

    it "leaves a name that already names its sport alone" do
      expect(titled("Boise Half Marathon")).to eq("2026 Boise Half Marathon")
    end

    it "falls back to the supplied filename when the track is unnamed" do
      parsed = described_class.new(
        StringIO.new('<gpx><trk><trkseg><trkpt lat="1.0" lon="2.0"/></trkseg></trk></gpx>'),
        fallback_name: "activity_123"
      )

      expect(parsed.title).to eq("activity_123 - Other")
    end
  end

  describe "#id" do
    it "is Mapbox-safe: at most 32 characters of alphanumerics and underscores" do
      expect(track.id).to match(/\A[a-z0-9_]{1,32}\z/)
    end

    # Two races whose names start with the same long text give the same slug after the cut. Thus the
    # digest is what keeps their tilesets separate.
    it "distinguishes titles that truncate to the same slug" do
      long = ->(suffix) {
        build(<<~XML).id
          <gpx><trk><name>Ironman 70.3 Boise Course #{suffix}</name><type>cycling</type><trkseg>
            <trkpt lat="1.0" lon="2.0"/>
          </trkseg></trk></gpx>
        XML
      }

      expect(long.call("Bike")).not_to eq(long.call("Run"))
    end

    it "is stable for the same title" do
      expect(track.id).to eq(File.open(fixture) { |io| described_class.new(io) }.id)
    end
  end

  describe "#bounds" do
    it "spans every point, with no margin applied" do
      expect(track.bounds).to eq(
        min_lon: -116.206274, max_lon: -116.055526, min_lat: 43.52207, max_lat: 43.607905
      )
    end
  end

  describe "#start_icon" do
    def icon_for(type)
      build(<<~XML).start_icon
        <gpx><trk><name>x</name><type>#{type}</type><trkseg><trkpt lat="1.0" lon="2.0"/></trkseg></trk></gpx>
      XML
    end

    it { expect(icon_for("running")).to eq("pitch") }
    it { expect(icon_for("road_biking")).to eq("bicycle-share") }
    it { expect(icon_for("open_water_swimming")).to eq("swimming") }
    # There is no neutral icon: a sport with no match gets the running icon.
    it { expect(icon_for("skiing")).to eq("pitch") }
  end
end
