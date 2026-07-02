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
    get "/api/weather/current", headers: auth_headers

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

  it "renders the full summary: forecast, sun times, and an activity suggestion" do
    get "/api/weather/current", headers: auth_headers

    expect(response.body).to include("forecast is clear, with a high of") # forecast()
    expect(response.body).to include("will be at")                        # sunrise_or_sunset()
    expect(response.body).to include("a good day to be outside!")         # activities() (mild, no workout)
    expect(response.body).to include("</span>")                           # sentences wrapped as spans
  end

  context "when it's race day" do
    let(:race) do
      DeepOstruct.wrap(
        title: "San Francisco Marathon",
        date: Time.now.in_time_zone("America/Los_Angeles").iso8601, # today, in the resolved zone
        going: true,
        tracking_url: nil,
        sys: { id: "sfm" }
      )
    end

    before { allow_any_instance_of(Events).to receive(:all).and_return([race]) }

    it "announces the race and weaves it into the summary" do
      get "/api/weather/current", headers: auth_headers

      expect(response.body).to include("race day")               # race_day()
      expect(response.body).to include("racing the")             # current_location()
      expect(response.body).to include("San Francisco Marathon")
      expect(response.body).to include("Good weather for racing!") # activities() (mild fixture)
    end
  end

  context "when there are active weather alerts" do
    before do
      weather.weather_alerts = DeepOstruct.wrap(alerts: [
        { token: "heat", precedence: 1, description: "Heat advisory", details_url: "https://example.com/alert" }
      ])
    end

    it "renders the alert with its link" do
      get "/api/weather/current", headers: auth_headers

      expect(response.body).to include("weather__alert")
      expect(response.body).to include("Heat advisory")
      expect(response.body).to include('href="https://example.com/alert"')
    end
  end

  it "sets the caching headers" do
    get "/api/weather/current", headers: auth_headers

    cache_control = response.headers["Cache-Control"]
    expect(cache_control).to include("public")
    expect(cache_control).to include("max-age=0")
    expect(cache_control).to include("stale-while-revalidate=300")

    edge = response.headers["Netlify-CDN-Cache-Control"]
    expect(edge).to include("durable")
    expect(edge).to include("max-age=300")
    expect(edge).to include("stale-while-revalidate=3600")
    expect(edge).to include("stale-if-error=86400")
  end

  it "embeds a relative same-origin refetch URL" do
    get "/api/weather/current", headers: auth_headers

    expect(response.body).to include('data-live-update-url-value="/api/weather/current"')
  end

  it "requires the API_TOKEN bearer (the proxy injects it; direct hits are rejected)" do
    get "/api/weather/current"
    expect(response).to have_http_status(:unauthorized)

    get "/api/weather/current", headers: { "Authorization" => "Bearer wrong" }
    expect(response).to have_http_status(:unauthorized)
  end

  context "when the weather upstream raises (e.g. a network timeout)" do
    before { allow_any_instance_of(WeatherKit).to receive(:data).and_raise(Net::ReadTimeout) }

    it "collapses the widget with an empty, non-durable response instead of a 500" do
      get "/api/weather/current", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
      expect(response.headers["Netlify-CDN-Cache-Control"]).not_to include("durable")
    end
  end

  context "when a non-critical upstream raises" do
    before { allow_any_instance_of(AirQuality).to receive(:data).and_raise(Net::ReadTimeout) }

    it "still renders the weather, just without that section" do
      get "/api/weather/current", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('class="weather"')
      expect(response.body).not_to include("AQI")
    end
  end

  context "when the weather is unavailable" do
    before { allow_any_instance_of(WeatherKit).to receive(:data).and_return(nil) }

    it "returns an empty body so the live-update controller collapses the placeholder" do
      get "/api/weather/current", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end
  end

  context "when the current location can't be resolved" do
    before { allow(Location).to receive(:new).and_return(double(latitude: nil, longitude: nil)) }

    it "returns an empty body without fetching weather" do
      get "/api/weather/current", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end
  end

  context "when the weather payload is missing current conditions" do
    before do
      stale = weather.dup
      stale.current_weather = nil
      allow_any_instance_of(WeatherKit).to receive(:data).and_return(stale)
    end

    it "treats the data as stale and returns an empty body" do
      get "/api/weather/current", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end
  end

  context "in the evening with no overnight forecast in the payload" do
    before do
      day = weather.forecast_daily.days.first
      day.sunset = (now - 1.hour).iso8601 # it's after sunset, so the summary reads overnight_forecast
      day.overnight_forecast = nil
      allow_any_instance_of(WeatherKit).to receive(:data).and_return(weather)
    end

    it "treats the data as stale and collapses instead of crashing on the missing slice" do
      get "/api/weather/current", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end
  end

  context "when no forecast day covers the current time" do
    before do
      future = weather.dup
      future.forecast_daily.days.first.forecast_start = (now + 2.days).iso8601
      future.forecast_daily.days.first.forecast_end = (now + 3.days).iso8601
      allow_any_instance_of(WeatherKit).to receive(:data).and_return(future)
    end

    it "treats the data as stale and returns an empty body" do
      get "/api/weather/current", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.strip).to be_empty
    end
  end
end
