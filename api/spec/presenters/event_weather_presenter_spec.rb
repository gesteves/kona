require "rails_helper"

RSpec.describe EventWeatherPresenter do
  def build_event(location_components:, precipitation_type: "rain")
    DeepOstruct.wrap(
      sys: { id: "abc123" },
      date: "2026-05-30T17:00:00Z",
      location: {
        geocoded: { address_components: location_components },
        time_zone: { time_zone_id: "America/Los_Angeles" }
      },
      aqi: { aqi: 42 },
      weather: {
        forecast_daily: {
          days: [
            {
              forecast_start: "2026-05-30",
              forecast_end: "2026-05-31",
              sunrise: "2026-05-30T13:00:00Z",
              sunset: "2026-05-31T03:00:00Z",
              daytime_forecast: { precipitation_type: precipitation_type, condition_code: "Clear" }
            }
          ]
        }
      }
    )
  end

  let(:sf_components) do
    [
      { long_name: "San Francisco", short_name: "SF", types: [ "locality", "political" ] },
      { long_name: "California", short_name: "CA", types: [ "administrative_area_level_1", "political" ] },
      { long_name: "United States", short_name: "US", types: [ "country", "political" ] }
    ]
  end
  let(:boulder_components) do
    [
      { long_name: "Boulder", short_name: "Boulder", types: [ "locality", "political" ] },
      { long_name: "Colorado", short_name: "CO", types: [ "administrative_area_level_1", "political" ] },
      { long_name: "United States", short_name: "US", types: [ "country", "political" ] }
    ]
  end

  describe "#forecast_day / #forecast" do
    subject(:presenter) { described_class.new(build_event(location_components: boulder_components)) }

    it "finds the forecast day covering the event date and its daytime forecast" do
      expect(presenter.forecast_day.sunrise).to eq("2026-05-30T13:00:00Z")
      expect(presenter.forecast.condition_code).to eq("Clear")
    end

    it "exposes sunrise, sunset, and the event timezone" do
      expect(presenter.sunrise).to eq("2026-05-30T13:00:00Z")
      expect(presenter.sunset).to eq("2026-05-31T03:00:00Z")
      expect(presenter.time_zone_id).to eq("America/Los_Angeles")
    end
  end

  describe "#precipitation_label" do
    it "returns the precipitation type, downcased" do
      presenter = described_class.new(build_event(location_components: boulder_components, precipitation_type: "Snow"))
      expect(presenter.precipitation_label).to eq("snow")
    end

    it "treats a 'clear' precipitation type as rain" do
      presenter = described_class.new(build_event(location_components: boulder_components, precipitation_type: "Clear"))
      expect(presenter.precipitation_label).to eq("rain")
    end
  end

  describe "#bay" do
    let(:goodspeed) do
      DeepOstruct.wrap(timeseries: [
        { t: "2026-05-30T17:05:00Z", water_temp_c: 15.0, current_speed_ms: 0.5, current_bearing_deg: 110, current_speed_kt: 1.0 }
      ])
    end

    it "returns the nearest bay entry when the event is in San Francisco" do
      presenter = described_class.new(build_event(location_components: sf_components), goodspeed: goodspeed)
      expect(presenter.bay&.water_temp_c).to eq(15.0)
    end

    it "returns nil when the event is not in San Francisco" do
      presenter = described_class.new(build_event(location_components: boulder_components), goodspeed: goodspeed)
      expect(presenter.bay).to be_nil
    end

    it "returns nil when there is no bay data" do
      presenter = described_class.new(build_event(location_components: sf_components), goodspeed: nil)
      expect(presenter.bay).to be_nil
    end
  end
  describe "the display rules of the bay readings and the forecast" do
    subject(:presenter) { described_class.new(build_event(location_components: sf_components)) }

    def with_bay(**fields)
      allow(presenter).to receive(:bay).and_return(DeepOstruct.wrap(fields))
    end

    it "shows the water temperature and the current only with each of their fields" do
      with_bay(water_temp_c: 13.5, current_speed_ms: 0.4)

      expect(presenter.water_temperature?).to be(true)
      expect(presenter.bay_current?).to be(false)
    end

    it "shows neither with no bay entry" do
      allow(presenter).to receive(:bay).and_return(nil)

      expect(presenter.water_temperature?).to be(false)
      expect(presenter.bay_current?).to be(false)
    end

    it "turns the bearing of the current into the direction that it comes from" do
      with_bay(current_speed_ms: 0.4, current_bearing_deg: 270)

      expect(presenter.bay_current?).to be(true)
      expect(presenter.bay_current_from).to eq(90)
    end

    it "gives the humidity and the chance of precipitation in percent" do
      allow(presenter).to receive(:forecast).and_return(DeepOstruct.wrap(humidity: 0.5, precipitation_chance: 0.25))

      expect(presenter.humidity_percent).to eq(50.0)
      expect(presenter.precipitation_percent).to eq(25.0)
    end
  end
end
