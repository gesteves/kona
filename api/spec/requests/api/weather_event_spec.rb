require "rails_helper"

RSpec.describe "Api::Weather event", type: :request do
  let(:event_date) { Time.now + 3.days }

  let(:event_record) do
    DeepOstruct.wrap(sys: { id: "abc123" }, date: event_date.iso8601, location: "The Rockies", coordinates: { lat: 40.01, lon: -105.27 })
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
    allow_any_instance_of(Events).to receive(:find).and_return(event_record)
    allow(GoogleMaps).to receive(:new).and_return(double(time_zone_id: "America/Denver", country_code: "US", location: location_hash))
    allow_any_instance_of(WeatherKit).to receive(:data).and_return(weather)
    allow(GoogleAirQuality).to receive(:new).and_return(double(aqi: { aqi: 42, category: "Good", description: "Good air quality" }))
    allow_any_instance_of(Goodspeed).to receive(:data).and_return(nil)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  it "renders the event weather markup" do
    get "/api/weather/event/abc123"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('class="event__weather"')
    expect(response.body).to include("Race Day Weather")
    expect(response.body).to include("The Rockies")   # the Contentful location label
    expect(response.body).to include("Partly cloudy")              # format_condition
    expect(response.body).to include("data-units-metric-value")    # temp/wind toggle
    expect(response.body).to include("AQI")
    expect(response.body).to include("42")
    expect(response.body).to include("<svg")
  end

  it "sets a one-hour caching header" do
    get "/api/weather/event/abc123"

    cache_control = response.headers["Cache-Control"]
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=3600")
  end

  it "allows cross-origin requests from any origin" do
    get "/api/weather/event/abc123", headers: { "Origin" => "https://example.com" }

    expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
  end

  context "when the event is not found" do
    before { allow_any_instance_of(Events).to receive(:find).and_return(nil) }

    it "returns an empty body" do
      get "/api/weather/event/nope"

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end
  end
end
