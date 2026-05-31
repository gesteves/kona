require "rails_helper"

RSpec.describe "Weather", type: :request do
  let(:now) { Time.now }

  let(:location_hash) do
    {
      geocoded: {
        address_components: [
          { long_name: "San Francisco", short_name: "SF", types: ["locality", "political"] },
          { long_name: "California", short_name: "CA", types: ["administrative_area_level_1", "political"] },
          { long_name: "United States", short_name: "US", types: ["country", "political"] }
        ]
      },
      time_zone: { time_zone_id: "America/Los_Angeles" },
      elevation: 16.0
    }
  end

  let(:weather) do
    DeepOstruct.wrap(
      current_weather: {
        condition_code: "PartlyCloudy",
        temperature: 18.4,
        temperature_apparent: 17.9,
        humidity: 0.55,
        wind_speed: 12.0,
        wind_direction: 270,
        wind_gust: 20.0
      },
      forecast_daily: {
        days: [
          {
            forecast_start: (now - 6.hours).iso8601,
            forecast_end: (now + 18.hours).iso8601,
            condition_code: "PartlyCloudy",
            temperature_max: 24.0,
            temperature_min: 11.0,
            sunrise: (now - 5.hours).iso8601,
            sunset: (now + 5.hours).iso8601,
            rest_of_day_forecast: { condition_code: "Clear", precipitation_chance: 0.1, precipitation_type: "clear", snowfall_amount: 0 },
            overnight_forecast: { condition_code: "Clear", precipitation_chance: 0.0, precipitation_type: "clear", snowfall_amount: 0 }
          }
        ]
      },
      weather_alerts: { alerts: [] }
    )
  end

  before do
    allow(Location).to receive(:new).and_return(double(latitude: 37.77, longitude: -122.42))
    allow(GoogleMaps).to receive(:new).and_return(double(time_zone_id: "America/Los_Angeles", country_code: "US", location: location_hash))
    allow_any_instance_of(WeatherKit).to receive(:data).and_return(weather)
    allow_any_instance_of(AirQuality).to receive(:data).and_return(DeepOstruct.wrap(aqi: 30, category: "Good", description: "Good air quality"))
    allow_any_instance_of(GooglePollen).to receive(:data).and_return(nil)
    allow_any_instance_of(Events).to receive(:all).and_return([])
    allow_any_instance_of(Goodspeed).to receive(:data).and_return(nil)
    allow_any_instance_of(TrainerRoad).to receive(:workouts).and_return([])
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  it "renders the weather markup" do
    get "/api/weather/current"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('class="weather"')
    expect(response.body).to include("weather__icon")
    expect(response.body).to include("<svg")                       # icon markup, rendered unescaped
    expect(response.body).to include("San Francisco, California")  # current location
    expect(response.body).to include("partly cloudy")             # current condition phrase
    expect(response.body).to include("temperature of")
    expect(response.body).to include("data-units-metric-value")   # the metric/imperial toggle
    expect(response.body).to include("AQI")
  end

  it "sets the caching headers" do
    get "/api/weather/current"

    cache_control = response.headers["Cache-Control"]
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=0")
    expect(cache_control).to include("stale-while-revalidate=300")

    edge = response.headers["Netlify-CDN-Cache-Control"]
    expect(edge).to include("durable")
    expect(edge).to include("max-age=300")
    expect(edge).to include("stale-while-revalidate=86400")
    expect(edge).to include("stale-if-error=86400")
  end

  it "embeds a relative same-origin refetch URL" do
    get "/api/weather/current"

    expect(response.body).to include('data-live-update-url-value="/api/weather/current"')
  end

  context "when the weather is unavailable" do
    before { allow_any_instance_of(WeatherKit).to receive(:data).and_return(nil) }

    it "returns an empty body so the live-update controller collapses the placeholder" do
      get "/api/weather/current"

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end
  end
end
