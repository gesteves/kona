require "rails_helper"

RSpec.describe "Admin location", type: :request do
  let(:owner_email) { "owner@example.com" }
  let(:public_token) { "pk.test-token" }
  let(:secret_token) { "sk.secret-token" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow(ENV).to receive(:[]).with("MAPBOX_ACCESS_TOKEN").and_return(public_token)
    allow(ENV).to receive(:[]).with("MAPBOX_SECRET_TOKEN").and_return(secret_token)
    allow(ENV).to receive(:[]).with("LOCATION").and_return(nil)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    stub_geocoding(place: "Jackson Hole, Wyoming", time_zone: "America/Denver")
    stub_stored_location("43.48,-110.76")
  end

  # The page previews what the weather widget would print, which means Google's geocoder. Stubbed
  # at GoogleMaps so the real format_location still runs on the way through.
  def stub_geocoding(place:, time_zone:)
    components = [
      { types: [ "administrative_area_level_2" ], long_name: "Teton County" },
      { types: [ "administrative_area_level_1" ], long_name: "Wyoming" },
      { types: [ "country" ], long_name: "United States" }
    ]
    geocoded = place ? { address_components: components } : nil

    allow_any_instance_of(GoogleMaps).to receive(:location)
      .and_return({ geocoded: geocoded, time_zone: nil, elevation: nil })
    allow_any_instance_of(GoogleMaps).to receive(:time_zone_id).and_return(time_zone)
  end

  def stub_stored_location(value)
    allow($redis).to receive(:get).and_call_original
    allow($redis).to receive(:get).with(Location::LOCATION_CACHE_KEY).and_return(value)
  end

  def sign_in!
    sign_in_as(email: owner_email)
  end

  describe "GET /location" do
    before { sign_in! }

    it "centers the map on the stored location and reports it" do
      get "/location"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("43.48, -110.76")
      # ⚠️ Mapbox takes longitude first; a latitude-first center puts the pin in the sea.
      expect(response.body).to include('data-location-map-center-value="[-110.76,43.48]"')
    end

    # The whole point of the heading: it's format_location's output, so it reads exactly as the
    # weather widget will — special cases (this is one) included.
    it "names the place the way the weather widget would, and the widgets' time zone" do
      get "/location"

      expect(response.body).to include("Jackson Hole, Wyoming")
      expect(response.body).to include("America/Denver")
    end

    it "falls back to the coordinates when the geocode resolves to nothing" do
      stub_geocoding(place: nil, time_zone: "America/Denver")

      get "/location"

      expect(response.body).not_to include("Nowhere yet")
      expect(response.body).to include("43.48, -110.76")
    end

    # ⚠️ The map runs in the browser, so its token is in the page. It must be the public one —
    # MAPBOX_SECRET_TOKEN carries tilesets:write, and StaticMap prefers it for *server-side*
    # rendering, which is exactly the fallback that must not happen here.
    it "renders the public Mapbox token and never the secret one" do
      get "/location"

      expect(response.body).to include(public_token)
      expect(response.body).not_to include(secret_token)
    end

    it "says so when there's no Mapbox token" do
      allow(ENV).to receive(:[]).with("MAPBOX_ACCESS_TOKEN").and_return(nil)

      get "/location"

      expect(response.body).to include("MAPBOX_ACCESS_TOKEN")
    end

    # Location prefers the env var, so a pin drop would write Redis and change nothing anyone reads.
    it "warns when LOCATION overrides whatever is stored" do
      allow(ENV).to receive(:[]).with("LOCATION").and_return("37.77,-122.42")

      get "/location"

      expect(response.body).to include("<code>LOCATION</code>")
      expect(response.body).to include("37.77, -122.42")
    end

    it "invites a first pin when nothing is stored" do
      stub_stored_location(nil)

      get "/location"

      expect(response.body).to include("Drop a pin on the map")
      expect(response.body).to include("data-location-map-center-value=\"#{LocationPresenter::WORLD_CENTER.to_json}\"")
    end

    # ⚠️ Web Awesome components over native elements, as everywhere else in the admin.
    it "renders its one control as a Web Awesome button" do
      get "/location"

      expect(response.body).to include("<wa-button")
      expect(response.body).not_to include("<button")
    end

    it "never lets an admin page be stored" do
      get "/location"

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["CDN-Cache-Control"]).to be_nil
    end
  end

  describe "POST /location" do
    before { sign_in! }

    it "stores the coordinates and syncs them" do
      expect($redis).to receive(:set).with(Location::LOCATION_CACHE_KEY, "37.7749,-122.4194")

      post "/location", params: { latitude: "37.7749", longitude: "-122.4194" }

      expect(response).to have_http_status(:ok)
      expect(LocationSyncJob).to have_enqueued_sidekiq_job(37.7749, -122.4194)
    end

    # The page updates its heading from this rather than reloading, so a stale name never sits
    # over a pin that's since moved.
    it "answers with the place the new pin resolves to" do
      allow($redis).to receive(:set)

      post "/location", params: { latitude: "37.7749", longitude: "-122.4194" }

      expect(response.parsed_body).to eq("place" => "Jackson Hole, Wyoming", "time_zone" => "America/Denver")
    end

    it "still stores the location when the geocode fails" do
      allow($redis).to receive(:set)
      allow_any_instance_of(GoogleMaps).to receive(:location).and_raise(StandardError, "Google is down")

      post "/location", params: { latitude: "37.7749", longitude: "-122.4194" }

      expect(response.parsed_body).to eq("place" => nil, "time_zone" => nil)
      expect(LocationSyncJob).to have_enqueued_sidekiq_job(37.7749, -122.4194)
    end

    it "refuses coordinates that aren't numbers" do
      expect($redis).not_to receive(:set)

      post "/location", params: { latitude: "somewhere", longitude: "else" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(LocationSyncJob.jobs).to be_empty
    end

    it "refuses coordinates outside the valid ranges" do
      expect($redis).not_to receive(:set)

      post "/location", params: { latitude: "91", longitude: "0" }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses missing coordinates" do
      post "/location", params: {}

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "without an owner session" do
    it "redirects the page to the login screen" do
      get "/location"

      expect(response).to redirect_to("/signin")
    end

    it "refuses to store anything" do
      expect($redis).not_to receive(:set)

      post "/location", params: { latitude: "37.7749", longitude: "-122.4194" }

      expect(response).to redirect_to("/signin")
      expect(LocationSyncJob.jobs).to be_empty
    end
  end
end
