require "rails_helper"

RSpec.describe "Api::Events upcoming", type: :request do
  let(:featured_event) do
    DeepOstruct.wrap(
      title: "Featured Race",
      summary: "A short summary.",
      description: 'Run <span data-imperial="6.2 mi">10 km</span> along the coast. Register at [the site](https://example.com).',
      location: "Boulder, Colorado",
      url: "https://example.com/race",
      tracking_url: nil,
      date: (Time.now + 3.days).iso8601,
      going: true,
      coordinates: { lat: 40.01, lon: -105.27 },
      sys: { id: "featured123" }
    )
  end

  let(:later_event) do
    DeepOstruct.wrap(
      title: "Later Race",
      summary: "Later in the season.",
      description: nil,
      location: "Moab, Utah",
      url: nil,
      tracking_url: nil,
      date: (Time.now + 30.days).iso8601,
      going: true,
      coordinates: { lat: 38.57, lon: -109.55 },
      sys: { id: "later456" }
    )
  end

  let(:location_hash) do
    {
      geocoded: {
        address_components: [
          { long_name: "Boulder", short_name: "Boulder", types: ["locality", "political"] },
          { long_name: "Colorado", short_name: "CO", types: ["administrative_area_level_1", "political"] },
          { long_name: "United States", short_name: "US", types: ["country", "political"] }
        ]
      },
      time_zone: { time_zone_id: "America/Denver" },
      elevation: 1655.0
    }
  end

  let(:weather) do
    event_date = Time.now + 3.days
    DeepOstruct.wrap(
      forecast_daily: {
        days: [
          {
            forecast_start: event_date.to_date.iso8601,
            forecast_end: (event_date.to_date + 1).iso8601,
            sunrise: event_date.change(hour: 6).iso8601,
            sunset: event_date.change(hour: 20).iso8601,
            daytime_forecast: {
              condition_code: "PartlyCloudy",
              temperature_min: 12.0,
              temperature_max: 22.0,
              humidity: 0.5,
              precipitation_chance: 0.2,
              precipitation_type: "rain",
              wind_speed: 14.0,
              wind_direction: 250,
              wind_speed_max: 20.0,
              wind_gust_speed_max: 30.0
            }
          }
        ]
      }
    )
  end

  before do
    allow_any_instance_of(Events).to receive(:all).and_return([featured_event, later_event])
    allow(GoogleMaps).to receive(:new).and_return(double(time_zone_id: "America/Denver", country_code: "US", location: location_hash))
    allow_any_instance_of(WeatherKit).to receive(:data).and_return(weather)
    allow(GoogleAirQuality).to receive(:new).and_return(double(aqi: { aqi: 42, category: "Good", description: "Good air quality" }))
    allow_any_instance_of(Goodspeed).to receive(:data).and_return(nil)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  it "renders the upcoming-races section as a live-update fragment" do
    get "/api/events/upcoming", headers: auth_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('class="collection')
    expect(response.body).to include("Upcoming Races")
    expect(response.body).to include("Featured Race")
    expect(response.body).to include("Later Race")
    # Outer element keeps refreshing after the static site swaps it in.
    expect(response.body).to include('data-controller="live-update"')
    expect(response.body).to include('data-live-update-url-value="/api/events/upcoming"')
  end

  it "features the next race within 10 days, with its race-day weather inline" do
    get "/api/events/upcoming", headers: auth_headers

    expect(response.body).to include("collection--has-featured")
    expect(response.body).to include("event--is-featured")
    expect(response.body).to include("Race Day Weather")
    expect(response.body).to include("Partly cloudy") # format_condition, from the featured forecast
  end

  it "renders the event body with unit toggles and external links opening in a new tab" do
    get "/api/events/upcoming", headers: auth_headers

    expect(response.body).to include("data-units-metric-value") # the <span data-imperial> conversion
    expect(response.body).to include('target="_blank"')         # external description link
    expect(response.body).to include("the site")
  end

  it "sets a one-hour durable caching header" do
    get "/api/events/upcoming", headers: auth_headers

    cache_control = response.headers["Cache-Control"]
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=0")
    expect(cache_control).to include("stale-while-revalidate=3600")

    edge = response.headers["Netlify-CDN-Cache-Control"]
    expect(edge).to include("durable")
    expect(edge).to include("max-age=3600")
    expect(edge).to include("stale-while-revalidate=86400")
    expect(edge).to include("stale-if-error=86400")
  end

  context "when the next race is more than 10 days out" do
    before { allow_any_instance_of(Events).to receive(:all).and_return([later_event]) }

    it "renders the section without a featured event or race-day weather" do
      get "/api/events/upcoming", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Later Race")
      expect(response.body).not_to include("collection--has-featured")
      expect(response.body).not_to include("Race Day Weather")
    end
  end

  context "when there are no upcoming races" do
    before { allow_any_instance_of(Events).to receive(:all).and_return([]) }

    it "returns an empty body so the placeholder collapses" do
      get "/api/events/upcoming", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end
  end

  context "when the featured event has a live-tracking link but isn't in progress" do
    before do
      tracked = DeepOstruct.wrap(
        title: "Featured Race",
        summary: "A short summary.",
        description: nil,
        location: "Boulder, Colorado",
        url: "https://example.com/race",
        tracking_url: "https://track.example.com/race",
        date: (Time.now + 3.days).iso8601,
        going: true,
        coordinates: { lat: 40.01, lon: -105.27 },
        sys: { id: "featured123" }
      )
      allow_any_instance_of(Events).to receive(:all).and_return([tracked, later_event])
    end

    it "renders a muted Live tracking link without the live highlight" do
      get "/api/events/upcoming", headers: auth_headers

      expect(response.body).to include("Live tracking")
      expect(response.body).to include('href="https://track.example.com/race"')
      expect(response.body).not_to include("entry__highlight--live")
    end
  end
end
