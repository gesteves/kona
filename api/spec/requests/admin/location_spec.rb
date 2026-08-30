require "rails_helper"

RSpec.describe "Admin location", type: :request do
  include ActiveSupport::Testing::TimeHelpers

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
    stub_geocoding(place: "Jackson Hole, Wyoming")
    stub_stored_location("43.48,-110.76")
    stub_events([])
  end

  def stub_events(events)
    allow_any_instance_of(Events).to receive(:all).and_return(DeepOstruct.wrap(events))
  end

  # ⚠️ `on:` becomes a 9am timestamp **with a zone**, as a Contentful date has. `Time.parse` reads a
  # plain "2026-10-10" in the zone of the *machine*. Thus a CI machine in UTC gives the day before,
  # in the zone that the page uses, and each date here moves back one day.
  def event(title:, on:, going: true, location: "Kona, Hawaii", lat: 19.64, lon: -155.99)
    date = ActiveSupport::TimeZone[TimeZoneResolver.default].parse("#{on} 09:00").iso8601
    { title: title, date: date, going: going, location: location, coordinates: { lat: lat, lon: lon } }
  end

  # The page shows the name that the weather widget would show, and that comes from the geocoder of
  # Google. The stub is at GoogleMaps, thus the true format_location still runs.
  def stub_geocoding(place:)
    components = [
      { types: [ "administrative_area_level_2" ], long_name: "Teton County" },
      { types: [ "administrative_area_level_1" ], long_name: "Wyoming" },
      { types: [ "country" ], long_name: "United States" }
    ]
    geocoded = place ? { address_components: components } : nil

    allow_any_instance_of(GoogleMaps).to receive(:location)
      .and_return({ geocoded: geocoded, time_zone: nil, elevation: nil })
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
      expect(response.body).to match(
        /<wa-badge[^>]*variant="success"[^>]*>#{Regexp.escape(I18n.t("admin.location.state.saved"))}</m
      )
      # ⚠️ Mapbox needs the longitude first. With the latitude first, the pin goes into the sea.
      expect(response.body).to include('data-location-map-center-value="[-110.76,43.48]"')
    end

    # This is the purpose of the heading: it is the output of format_location, thus it reads exactly
    # as it reads in the weather widget. This includes each special condition, and this is one.
    it "names the place the way the weather widget would, and the widgets' time zone" do
      get "/location"

      expect(response.body).to include("Jackson Hole, Wyoming")
    end

    it "falls back to the coordinates when the geocode resolves to nothing" do
      stub_geocoding(place: nil)

      get "/location"

      expect(response.body).not_to include(I18n.t("admin.location.empty_heading"))
      expect(response.body).to include("43.48, -110.76")
    end

    # ⚠️ The map runs in the browser, thus its token is in the page. It must be the public token.
    # MAPBOX_SECRET_TOKEN has tilesets:write, and StaticMap uses it first for a render on the
    # *server*. That is the value that must never appear here.
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

    # Location uses the env var first, thus a pin writes to Redis and changes nothing that a person
    # reads.
    it "warns when LOCATION overrides whatever is stored" do
      allow(ENV).to receive(:[]).with("LOCATION").and_return("37.77,-122.42")

      get "/location"

      expect(response.body).to include("<code>LOCATION</code>")
      expect(response.body).to include("37.77, -122.42")
    end

    it "invites a first pin when nothing is stored" do
      stub_stored_location(nil)

      get "/location"

      expect(response.body).to include(I18n.t("admin.location.prompt"))
      expect(response.body).to match(/<wa-badge[^>]*variant="neutral"[^>]*>Not set</m)
      expect(response.body).to include("data-location-map-center-value=\"#{LocationPresenter::WORLD_CENTER.to_json}\"")
    end

    # Nothing is staged at the first render, thus there is nothing to write and nothing to remove.
    it "renders Save and Undo disabled, and the lookup it stages through" do
      get "/location"

      expect(response.body).to include(I18n.t("admin.location.show.save"))
      expect(response.body).to include(I18n.t("admin.location.show.undo"))
      expect(response.body.scan(/<wa-button[^>]*\sdisabled/m).size).to eq(2)
      expect(response.body).to include('data-location-map-lookup-url-value="/location/lookup"')
    end

    # ⚠️ Use a Web Awesome component in place of a native element, as in each other admin page.
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

  # ⚠️ The badge of the server and the badge of the browser must say the same words.
  # `LocationPresenter#state_label` renders the first state, and location_map_controller.js renders
  # each state after that. Both read `admin.location.state`, and this spec is what keeps them
  # together: the words reach the browser in this attribute and nowhere else.
  describe "the words that the map controller renders" do
    before { sign_in! }

    it "hands the browser the same state words that the presenter uses" do
      get "/location"

      table = JSON.parse(
        Nokogiri::HTML(response.body).at_css("[data-controller='location-map']")["data-admin-i18n"]
      )

      expect(table["state"]).to eq(I18n.t("admin.location.state").deep_stringify_keys)
      expect(table["state"]["saved"]).to eq(I18n.t("admin.location.state.saved"))
      expect(table["map_failed"]).to eq(I18n.t("admin.js.location.map_failed"))
    end
  end

  describe "the race shortcuts" do
    before { sign_in! }

    it "lists the confirmed races ahead, with the coordinates their buttons post" do
      travel_to(Time.utc(2026, 8, 20, 18, 0, 0)) do
        stub_events([
          event(title: "Kona", on: "2026-10-10"),
          event(title: "Boulder", on: "2026-09-01", location: "Boulder, Colorado", lat: 40.01, lon: -105.27),
          event(title: "Last year’s", on: "2025-10-10")
        ])

        get "/location"

        expect(response.body).to include("Boulder, Colorado")
        expect(response.body).to include('data-latitude="19.64"')
        expect(response.body).to include('data-longitude="-155.99"')
        expect(response.body).not_to include("Last year’s")
        # The soonest race is first.
        expect(response.body.index("Boulder")).to be < response.body.index("Kona")
      end
    end

    it "leaves the section out when there's nothing ahead" do
      get "/location"

      expect(response.body).not_to include(I18n.t("admin.location.show.races"))
    end

    # Contentful is one more upstream service, and this page works without it.
    it "still renders the map when the events can't be fetched" do
      allow_any_instance_of(Events).to receive(:all).and_call_original
      allow(HTTParty).to receive(:post).and_raise(StandardError, "Contentful is down")

      get "/location"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-controller=\"location-map\"")
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

    # The page changes its heading from this response and does not load the page again. Thus an old
    # name never stays above a pin that moved.
    it "answers with the place the new pin resolves to" do
      allow($redis).to receive(:set)

      post "/location", params: { latitude: "37.7749", longitude: "-122.4194" }

      expect(response.parsed_body).to eq(
        "latitude" => 37.7749, "longitude" => -122.4194, "place" => "Jackson Hole, Wyoming"
      )
    end

    it "still stores the location when the geocode fails" do
      allow($redis).to receive(:set)
      allow_any_instance_of(GoogleMaps).to receive(:location).and_raise(StandardError, "Google is down")

      post "/location", params: { latitude: "37.7749", longitude: "-122.4194" }

      expect(response.parsed_body["place"]).to be_nil
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

    # ⚠️ This takes coordinates only. The lookup resolves an address first, thus this action stores
    # one shape of data and one place decides what a correct location is.
    it "ignores an address, which is the lookup's job" do
      expect_any_instance_of(GoogleGeocoder).not_to receive(:coordinates)
      expect($redis).not_to receive(:set)

      post "/location", params: { address: "1 Ferry Building, San Francisco" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(LocationSyncJob.jobs).to be_empty
    end
  end

  describe "GET /location/lookup" do
    before do
      sign_in!
      # No code here can write. Each example runs with a store that raises on a write.
      allow($redis).to receive(:set).and_raise("the lookup must not write")
    end

    it "geocodes an address and names where it landed, without storing it" do
      allow_any_instance_of(GoogleGeocoder).to receive(:coordinates).and_return([ 37.7749, -122.4194 ])

      get "/location/lookup", params: { address: "1 Ferry Building, San Francisco" }

      expect(response.parsed_body).to eq(
        "latitude" => 37.7749, "longitude" => -122.4194, "place" => "Jackson Hole, Wyoming"
      )
      expect(LocationSyncJob.jobs).to be_empty
    end

    # The name that the page shows for a pin, before a person presses Save.
    it "names a coordinate pair, without storing it" do
      get "/location/lookup", params: { latitude: "37.7749", longitude: "-122.4194" }

      expect(response.parsed_body).to eq(
        "latitude" => 37.7749, "longitude" => -122.4194, "place" => "Jackson Hole, Wyoming"
      )
      expect(LocationSyncJob.jobs).to be_empty
    end

    it "refuses an address that resolves to nothing" do
      allow_any_instance_of(GoogleGeocoder).to receive(:coordinates).and_return(nil)

      get "/location/lookup", params: { address: "asdfgh" }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses coordinates that aren't usable" do
      get "/location/lookup", params: { latitude: "91", longitude: "0" }

      expect(response).to have_http_status(:unprocessable_content)
    end

    # ⚠️ A change to the address for an incorrect pair would find a place that the caller did not ask
    # for, and the page would stage that place.
    it "never falls back to the address when a coordinate was sent too" do
      expect_any_instance_of(GoogleGeocoder).not_to receive(:coordinates)

      get "/location/lookup", params: { latitude: "somewhere", longitude: "else", address: "Kona" }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "without an owner session" do
    it "redirects the page to the login screen" do
      get "/location"

      expect(response).to redirect_to("/signin")
    end

    it "refuses to resolve a location" do
      get "/location/lookup", params: { latitude: "37.7749", longitude: "-122.4194" }

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
