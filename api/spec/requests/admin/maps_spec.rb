require "rails_helper"

RSpec.describe "Admin maps", type: :request do
  let(:owner_email) { "owner@example.com" }
  let(:library) { instance_double(TrackLibrary) }

  let(:ready_track) do
    {
      "id" => "morning_run_abc",
      "title" => "2026 Morning Run",
      "activity_type" => "Running",
      "status" => "ready",
      "uploaded_at" => "2026-07-25T13:32:14Z",
      "tileset_id" => "testuser.morning_run_abc",
      "source_layer" => "track",
      "bounds" => { "min_lon" => 10.0, "max_lon" => 11.0, "min_lat" => 50.0, "max_lat" => 51.0 },
      "start_coord" => [ 10.0, 50.0 ],
      "end_coord" => [ 11.0, 51.0 ],
      "settings" => StaticMap.defaults_for("pitch")
    }
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow(ENV).to receive(:[]).with("MAPBOX_USERNAME").and_return("testuser")
    allow(ENV).to receive(:[]).with("MAPBOX_SECRET_TOKEN").and_return("sk.test-token")
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    allow(TrackLibrary).to receive(:new).and_return(library)
    allow(library).to receive(:all).and_return([])
    allow(library).to receive(:find).and_return(nil)
  end

  def sign_in! = sign_in_as(email: owner_email)

  def gpx_upload(name = "track.gpx")
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/track.gpx"), "application/gpx+xml", original_filename: name)
  end

  describe "GET /maps" do
    before { sign_in! }

    it "renders an empty state when nothing has been uploaded" do
      get "/maps"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No tracks yet")
    end

    it "lists a track with its status and shape" do
      allow(library).to receive(:all).and_return([ ready_track ])

      get "/maps"

      expect(response.body).to include("2026 Morning Run", "Ready", "Running")
      expect(response.body).to include('<wa-button href="/maps/morning_run_abc"')
    end

    it "shows a spinner and no Open button while Mapbox is still publishing" do
      allow(library).to receive(:all).and_return([ ready_track.merge("status" => "processing") ])

      get "/maps"

      expect(response.body).to include("Processing", "<wa-spinner>")
      expect(response.body).not_to include('<wa-button href="/maps/morning_run_abc"')
    end

    it "surfaces why a track failed" do
      allow(library).to receive(:all).and_return([ ready_track.merge("status" => "failed", "error" => "bad geometry") ])

      get "/maps"

      expect(response.body).to include("Failed", "bad geometry")
    end

    # ⚠️ The one admin page whose core function needs the worker. Locally it's opt-in, so without
    # this a track spins on "Processing" forever with nothing saying why.
    it "says so when nothing is draining the queue" do
      allow(library).to receive(:all).and_return([ ready_track.merge("status" => "processing") ])
      allow(Sidekiq::ProcessSet).to receive(:new).and_return(instance_double(Sidekiq::ProcessSet, size: 0))

      get "/maps"

      expect(response.body).to include("No Sidekiq worker is running")
    end

    it "stays quiet about the worker when one is running" do
      allow(library).to receive(:all).and_return([ ready_track.merge("status" => "processing") ])
      allow(Sidekiq::ProcessSet).to receive(:new).and_return(instance_double(Sidekiq::ProcessSet, size: 1))

      get "/maps"

      expect(response.body).not_to include("No Sidekiq worker is running")
    end

    # Nothing is publishing, so the worker is irrelevant — don't pay for the Redis read.
    it "doesn't check the worker when nothing is processing" do
      allow(library).to receive(:all).and_return([ ready_track ])
      expect(Sidekiq::ProcessSet).not_to receive(:new)

      get "/maps"
    end

    it "says so when Mapbox isn't configured" do
      allow(ENV).to receive(:[]).with("MAPBOX_SECRET_TOKEN").and_return(nil)

      get "/maps"

      expect(response.body).to include("MAPBOX_SECRET_TOKEN")
    end

    # ⚠️ Web Awesome components over native elements. A bare <button> means a `button_to` crept in.
    it "renders actions as Web Awesome buttons, not native ones" do
      allow(library).to receive(:all).and_return([ ready_track ])

      get "/maps"

      expect(response.body).to include("<wa-button type=\"submit\"")
      expect(response.body).not_to include("<button")
    end

    it "never lets an admin page be stored or indexed" do
      get "/maps"

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
      expect(response.headers["CDN-Cache-Control"]).to be_nil
    end
  end

  describe "POST /maps" do
    before do
      sign_in!
      allow(library).to receive(:stage).and_return("morning_run_abc")
    end

    it "parses the upload, stages it, and queues the publish" do
      post "/maps", params: { gpx_files: [ gpx_upload ] }

      expect(library).to have_received(:stage).with(instance_of(GpxTrack))
      expect(MapTilesetJob).to have_enqueued_sidekiq_job("morning_run_abc")
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to include("Ironman 70.3 Boise")
    end

    it "takes several files at once" do
      post "/maps", params: { gpx_files: [ gpx_upload("a.gpx"), gpx_upload("b.gpx") ] }

      expect(library).to have_received(:stage).twice
    end

    it "refuses a file that isn't a GPX" do
      post "/maps", params: { gpx_files: [ gpx_upload("notes.txt") ] }

      expect(library).not_to have_received(:stage)
      expect(flash[:alert]).to include("isn't a GPX file")
    end

    it "refuses more files than it will take at once" do
      post "/maps", params: { gpx_files: Array.new(11) { gpx_upload } }

      expect(library).not_to have_received(:stage)
      expect(flash[:alert]).to include("at most 10")
    end

    it "asks for a file when none was chosen" do
      post "/maps", params: {}

      expect(flash[:alert]).to include("at least one GPX file")
    end

    # An empty file field posts a blank string, and a hand-rolled request can post anything.
    it "ignores a value that isn't an upload at all" do
      post "/maps", params: { gpx_files: [ "", "not-a-file" ] }

      expect(library).not_to have_received(:stage)
      expect(flash[:alert]).to include("at least one GPX file")
    end

    # One unparseable track in a batch must not lose the others.
    it "reports a bad track and keeps the good ones" do
      allow(GpxTrack).to receive(:new).and_invoke(
        ->(*) { raise GpxTrack::ParseError, "No track points found in GPX file" },
        ->(io, **opts) { GpxTrack.allocate.tap { |t| t.send(:initialize, io, **opts) } }
      )

      post "/maps", params: { gpx_files: [ gpx_upload("bad.gpx"), gpx_upload("good.gpx") ] }

      expect(library).to have_received(:stage).once
      expect(flash[:alert]).to include("bad.gpx")
      expect(flash[:notice]).to include("Uploading")
    end
  end

  describe "GET /maps/status" do
    before { sign_in! }

    it "returns just the statuses" do
      allow(library).to receive(:statuses).and_return("morning_run_abc" => "processing")

      get "/maps/status"

      expect(response.parsed_body).to eq("morning_run_abc" => "processing")
    end

    # ⚠️ Drawn above /maps/:id, or it's swallowed as a track id.
    it "isn't mistaken for a track" do
      allow(library).to receive(:statuses).and_return({})

      get "/maps/status"

      expect(response).to have_http_status(:ok)
      expect(library).not_to have_received(:find)
    end
  end

  describe "GET /maps/:id" do
    before do
      sign_in!
      allow(library).to receive(:find).with("morning_run_abc").and_return(ready_track)
    end

    it "renders the settings form and the preview" do
      get "/maps/morning_run_abc"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="settings[padding_top]"', 'name="settings[padding_left]"',
        'name="settings[margin_bottom]"', 'name="settings[track_color]"',
        'name="settings[start_icon]"', 'name="settings[style_preset]"', 'name="settings[style_url]"')
      expect(response.body).to include("/maps/morning_run_abc/preview")
      expect(response.body).to include("/maps/morning_run_abc/download")
    end

    # An unchecked switch submits nothing, so the pair is what makes "off" reach the server.
    it "pairs the marker-order switch with a hidden field" do
      get "/maps/morning_run_abc"

      expect(response.body).to include('<input type="hidden" name="settings[finish_on_top]" value="0">')
      expect(response.body).to include('<wa-switch name="settings[finish_on_top]" value="1"')
    end

    it "lets query-string settings override the stored ones, for the no-JS path" do
      get "/maps/morning_run_abc", params: { settings: { padding_top: "99" } }

      expect(response.body).to include('value="99"')
      expect(response.body).to include("settings%5Bpadding_top%5D=99")
    end

    describe "the zoom dialog" do
      it "makes the preview a trigger for a full-size dialog" do
        get "/maps/morning_run_abc"

        expect(response.body).to include('data-dialog="open map-preview-full"')
        expect(response.body).to include('<wa-dialog id="map-preview-full"')
      end

      # ⚠️ Same URL as the inline preview, so opening the dialog reuses the browser's cached copy.
      # A larger render here would be a second billed Mapbox request for the same map.
      it "reuses the preview's image rather than rendering again" do
        get "/maps/morning_run_abc"

        expect(response.body.scan(%r{src="/maps/morning_run_abc/preview[^"]*"}).uniq.length).to eq(1)
        expect(response.body.scan('data-map-preview-target="image"').length).to eq(2)
      end
    end

    it "sends you back when the track is gone" do
      allow(library).to receive(:find).with("nope").and_return(nil)

      get "/maps/nope"

      expect(response).to redirect_to("/maps")
      expect(flash[:alert]).to include("no longer in the library")
    end
  end

  describe "PATCH /maps/:id" do
    before { sign_in! }

    it "saves the settings" do
      allow(library).to receive(:update_settings).and_return(ready_track)

      patch "/maps/morning_run_abc", params: { settings: { padding_top: "80" } }

      expect(library).to have_received(:update_settings).with("morning_run_abc", hash_including("padding_top" => "80"))
      expect(response).to have_http_status(:no_content)
    end

    it "404s a track that's gone" do
      allow(library).to receive(:update_settings).and_return(nil)

      patch "/maps/nope", params: { settings: { padding_top: "80" } }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /maps/:id/preview and /download" do
    before do
      sign_in!
      allow(library).to receive(:find).with("morning_run_abc").and_return(ready_track)
      allow_any_instance_of(StaticMap).to receive(:render).and_return("PNGDATA")
    end

    it "streams the preview inline" do
      get "/maps/morning_run_abc/preview"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.body).to eq("PNGDATA")
      expect(response.headers["Content-Disposition"]).to start_with("inline")
    end

    it "offers the download as an attachment named after the track" do
      get "/maps/morning_run_abc/download"

      expect(response.headers["Content-Disposition"]).to include("attachment", "2026-morning-run.png")
    end

    # ⚠️ The Static Images URL carries MAPBOX_SECRET_TOKEN in a query parameter, which is why
    # these proxy the render instead of redirecting the browser to Mapbox.
    it "never puts the Mapbox token in the response" do
      get "/maps/morning_run_abc/preview"

      expect(response.body).not_to include("sk.test-token")
      expect(response.headers["Location"]).to be_nil
    end

    # Same render for both; only the disposition differs. The zoom dialog shows the preview at full
    # width, and a smaller render would save nothing — Mapbox bills per request, not per pixel.
    it "renders both at the same size" do
      get "/maps/morning_run_abc/preview"
      inline = response.body

      get "/maps/morning_run_abc/download"

      expect(response.body).to eq(inline)
    end

    it "applies query-string settings, so the preview tracks the form" do
      expect(StaticMap).to receive(:new)
        .with(hash_including(settings: hash_including("padding_top" => "12"))).and_call_original

      get "/maps/morning_run_abc/preview", params: { settings: { padding_top: "12" } }
    end

    # A broken <img> beats a redirect to an HTML page rendered into an image slot.
    it "answers with a status rather than a redirect when the track is gone" do
      allow(library).to receive(:find).with("nope").and_return(nil)

      get "/maps/nope/preview"

      expect(response).to have_http_status(:not_found)
    end

    it "refuses to render a track Mapbox hasn't published yet" do
      allow(library).to receive(:find).with("morning_run_abc").and_return(ready_track.merge("status" => "processing"))

      get "/maps/morning_run_abc/preview"

      expect(response).to have_http_status(:conflict)
    end

    it "reports a Mapbox failure as a bad gateway" do
      allow_any_instance_of(StaticMap).to receive(:render).and_raise(StaticMap::RenderError, "Tileset not found")

      get "/maps/morning_run_abc/preview"

      expect(response).to have_http_status(:bad_gateway)
    end
  end

  describe "DELETE /maps/:id" do
    before do
      sign_in!
      allow(library).to receive(:find).with("morning_run_abc").and_return(ready_track)
      allow(library).to receive(:delete).and_return(true)
    end

    it "removes it from Mapbox and from the library" do
      expect_any_instance_of(MapboxTileset).to receive(:destroy!).with("morning_run_abc")

      delete "/maps/morning_run_abc"

      expect(library).to have_received(:delete).with("morning_run_abc")
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to include("2026 Morning Run")
    end

    # Dropping the local record while the remote tileset survives would hide it forever.
    it "keeps the record when Mapbox refuses" do
      allow_any_instance_of(MapboxTileset).to receive(:destroy!).and_raise("Mapbox failed to delete tileset: Forbidden")

      delete "/maps/morning_run_abc"

      expect(library).not_to have_received(:delete)
      expect(flash[:alert]).to include("Forbidden")
    end
  end

  describe "without an owner session" do
    it "redirects every page to the login screen" do
      [ "/maps", "/maps/morning_run_abc" ].each do |path|
        get path
        expect(response).to redirect_to("/signin")
      end
    end

    it "refuses to upload, render, or delete" do
      expect(library).not_to receive(:stage)
      expect(library).not_to receive(:delete)

      post "/maps", params: { gpx_files: [ gpx_upload ] }
      expect(response).to redirect_to("/signin")

      get "/maps/morning_run_abc/download"
      expect(response).to redirect_to("/signin")

      delete "/maps/morning_run_abc"
      expect(response).to redirect_to("/signin")
    end
  end
end
