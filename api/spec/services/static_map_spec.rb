require "rails_helper"

RSpec.describe StaticMap do
  let(:record) do
    {
      "id" => "morning_run_4e481c66",
      "title" => "2026 Morning Run",
      "tileset_id" => "testuser.morning_run_4e481c66",
      "source_layer" => "track",
      "bounds" => { "min_lon" => 10.0, "max_lon" => 11.0, "min_lat" => 50.0, "max_lat" => 51.0 },
      "start_coord" => [ 10.0, 50.0 ],
      "end_coord" => [ 11.0, 51.0 ]
    }
  end

  def map(settings = {})
    described_class.new(track: record, settings: described_class.defaults_for("pitch").merge(settings))
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAPBOX_SECRET_TOKEN").and_return("sk.test-token")
    allow(ENV).to receive(:[]).with("MAPBOX_STYLE_URL").and_return("mapbox://styles/testuser/teststyle")
  end

  describe "#url" do
    # Pinned whole, because the parameter order and the raw (unencoded) addlayer JSON are both
    # part of what Mapbox accepts, and neither is obvious from the code.
    it "builds the Static Images request" do
      expect(map.url).to eq(
        "https://api.mapbox.com/styles/v1/testuser/teststyle/static/" \
        "pin-l-racetrack+f90f1a(11.0,51.0),pin-l-pitch+18a644(10.0,50.0)/" \
        "%5B10.0,50.0,11.0,51.0%5D/1280x1280@2x?access_token=sk.test-token&padding=50%2C50%2C50%2C50" \
        '&addlayer={"id":"testuser.morning_run_4e481c66","type":"line",' \
        '"source":{"type":"vector","url":"mapbox://testuser.morning_run_4e481c66"},' \
        '"source-layer":"track","paint":{"line-color":"%23bf0222","line-width":4.0,' \
        '"line-opacity":0.75,"line-cap":"round","line-join":"round"}}&before_layer=road-label'
      )
    end

    # The API bills per request, not per pixel, so there is no cheaper size to render.
    it "always asks for the retina render" do
      expect(map.url).to include("@2x")
    end

    it "omits the track layer until the tileset is published" do
      record["tileset_id"] = nil

      expect(map.url).not_to include("addlayer")
    end

    it "prefers the public token when no secret one is set" do
      allow(ENV).to receive(:[]).with("MAPBOX_SECRET_TOKEN").and_return(nil)
      allow(ENV).to receive(:[]).with("MAPBOX_ACCESS_TOKEN").and_return("pk.public")

      expect(map.url).to include("access_token=pk.public")
    end

    it "raises rather than rendering unauthenticated" do
      allow(ENV).to receive(:[]).with("MAPBOX_SECRET_TOKEN").and_return(nil)
      allow(ENV).to receive(:[]).with("MAPBOX_ACCESS_TOKEN").and_return(nil)

      expect { map.url }.to raise_error(described_class::RenderError, /token is missing/)
    end
  end

  describe "markers" do
    # ⚠️ Mapbox draws the last overlay on top, so start-on-top means listing the start marker last.
    it "puts the start pin on top by default" do
      expect(map.url).to include("pin-l-racetrack+f90f1a(11.0,51.0),pin-l-pitch+18a644(10.0,50.0)")
    end

    it "puts the finish pin on top when asked" do
      expect(map("finish_on_top" => "1").url).to include("pin-l-pitch+18a644(10.0,50.0),pin-l-racetrack+f90f1a(11.0,51.0)")
    end

    # The setting round-trips through JSON and a checkbox pair, so "0" has to read as false.
    it "treats a stringy false as off" do
      expect(map("finish_on_top" => "0").url).to include("pin-l-racetrack+f90f1a(11.0,51.0),pin-l-pitch")
    end

    it "uses the icons and colors it's given" do
      url = map("start_icon" => "swimming", "start_color" => "#00FF00", "end_icon" => "danger").url

      expect(url).to include("pin-l-danger+f90f1a(11.0,51.0)", "pin-l-swimming+00ff00(10.0,50.0)")
    end

    # These reach the URL from a form field, so anything that isn't an icon id or a hex color has
    # to be stripped rather than interpolated.
    it "strips anything that isn't an icon id or a color" do
      url = map("start_icon" => "swim)+bad(", "start_color" => "nonsense").url

      expect(url).to include("pin-l-swimbad+000000(10.0,50.0)")
    end
  end

  describe "the track layer" do
    it "passes the styling through, with the color escaped for the query string" do
      url = map("track_color" => "#123abc", "track_width" => "8", "track_opacity" => "0.4").url

      expect(url).to include('"line-color":"%23123abc"', '"line-width":8.0', '"line-opacity":0.4')
    end

    it "clamps opacity into range" do
      expect(map("track_opacity" => "4").url).to include('"line-opacity":1.0')
    end
  end

  describe "the map style" do
    it "uses the style it's given" do
      expect(map("style_url" => "mapbox://styles/someone/winter").url)
        .to include("/styles/v1/someone/winter/static/")
    end

    # ⚠️ The style reaches an outbound URL from a form field. Anything that isn't a Mapbox style
    # falls back rather than being interpolated.
    it "falls back to the default when the style isn't a Mapbox style URL" do
      expect(map("style_url" => "https://evil.example.com/x/y").url)
        .to include("/styles/v1/mapbox/outdoors-v12/static/")
    end
  end

  describe "framing" do
    it "expands the bounding box by the per-side margins, in kilometers" do
      url = map("margin_top" => 11.132).url # 11.132km ≈ 0.1° of latitude

      expect(url).to include("%5B10.0,50.0,11.0,51.1%5D")
    end

    it "sends padding to Mapbox in top,right,bottom,left order" do
      url = map("padding_top" => 10, "padding_right" => 20, "padding_bottom" => 30, "padding_left" => 40).url

      expect(url).to include("padding=10%2C20%2C30%2C40")
    end

    # These come from number fields, so a stray keystroke shouldn't ask Mapbox for something absurd.
    it "clamps a runaway side value" do
      expect(map("padding_top" => 99_999).url).to include("padding=500%2C50%2C50%2C50")
    end

    it "derives the height from the track's shape when none is set" do
      # A wide, shallow box: 1° of longitude at 50°N is much shorter than 1° of latitude.
      record["bounds"] = { "min_lon" => 10.0, "max_lon" => 12.0, "min_lat" => 50.0, "max_lat" => 50.1 }

      expect(map.url).to include("/1280x800@2x?") # clamped at the floor
    end

    it "honors a requested height, clamped" do
      expect(map("height" => "900").url).to include("/1280x900@2x?")
      expect(map("height" => "4000").url).to include("/1280x1280@2x?")
    end

    # Otherwise there'd be no room left to draw in.
    it "ignores a height that doesn't clear the vertical padding" do
      expect(map("height" => "40", "padding" => "50").url).to include("/1280x1280@2x?")
    end
  end

  describe "#render" do
    it "returns the image bytes" do
      allow(HTTParty).to receive(:get).and_return(instance_double(HTTParty::Response, success?: true, body: "PNGDATA"))

      expect(map.render).to eq("PNGDATA")
    end

    it "retries a server error, then gives up" do
      response = instance_double(HTTParty::Response, success?: false, code: 502, body: "{}")
      allow(HTTParty).to receive(:get).and_return(response)
      allow_any_instance_of(described_class).to receive(:sleep)

      expect { map.render }.to raise_error(described_class::RenderError)
      expect(HTTParty).to have_received(:get).exactly(3).times
    end

    it "surfaces Mapbox's own message on a client error" do
      response = instance_double(HTTParty::Response, success?: false, code: 422,
        body: { message: "Tileset not found" }.to_json)
      allow(HTTParty).to receive(:get).and_return(response)

      expect { map.render }.to raise_error(described_class::RenderError, /Tileset not found/)
    end
  end

  describe "#filename" do
    it "slugs the track's title" do
      expect(map.filename).to eq("2026-morning-run.png")
    end
  end
end
