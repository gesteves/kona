require "rails_helper"

RSpec.describe RaceDayWeather do
  let(:days_until) { 3 }
  let(:event) do
    DeepOstruct.wrap(sys: { id: "e1" }, date: (Time.current + days_until.days).change(hour: 12).iso8601,
                     location: "Boulder, CO", coordinates: { lat: 40.0, lon: -105.0 })
  end
  let(:gmaps) { instance_double(GoogleMaps, country_code: "US", location: DeepOstruct.wrap(address_components: [])) }
  let(:weather) { instance_double(WeatherKit, data: DeepOstruct.wrap(current_weather: { temperature: 10 })) }
  let(:air_quality) { instance_double(GoogleAirQuality, aqi: { aqi: 40, category: "Good" }) }
  let(:goodspeed) { instance_double(Goodspeed, data: DeepOstruct.wrap(timeseries: [])) }

  before do
    allow(GoogleMaps).to receive(:new).with(40.0, -105.0).and_return(gmaps)
    allow(TimeZoneResolver).to receive(:call).with(40.0, -105.0).and_return("America/Denver")
    allow(WeatherKit).to receive(:new).and_return(weather)
    allow(GoogleAirQuality).to receive(:new).and_return(air_quality)
    allow(Goodspeed).to receive(:new).and_return(goodspeed)
    allow(EventWeatherPresenter).to receive(:new).and_call_original
  end

  it "makes a presenter with the forecast and the AQI for a race in the next days" do
    presenter = described_class.for(event)

    expect(presenter).to be_a(EventWeatherPresenter)
    expect(WeatherKit).to have_received(:new).with(40.0, -105.0, "America/Denver", "US")
    expect(EventWeatherPresenter).to have_received(:new)
      .with(satisfy { |record| record.weather.current_weather.temperature == 10 && record.aqi.aqi == 40 }, goodspeed: nil)
  end

  context "when the race is past the AQI window and inside the forecast window" do
    let(:days_until) { 7 }

    it "reads the forecast and not the AQI" do
      described_class.for(event)

      expect(WeatherKit).to have_received(:new)
      expect(GoogleAirQuality).not_to have_received(:new)
    end
  end

  context "when the race is past the forecast window" do
    let(:days_until) { 12 }

    it "reads no forecast, and still makes the presenter" do
      expect(described_class.for(event)).to be_a(EventWeatherPresenter)
      expect(WeatherKit).not_to have_received(:new)
    end
  end

  it "gives nil with no coordinates, and asks nothing" do
    expect(described_class.for(DeepOstruct.wrap(sys: { id: "e1" }, date: event.date))).to be_nil
    expect(GoogleMaps).not_to have_received(:new)
  end

  it "gives nil for an event with no date, or with a date that does not parse" do
    expect(described_class.for(DeepOstruct.wrap(sys: { id: "e1" }, date: nil, coordinates: { lat: 40.0, lon: -105.0 }))).to be_nil
    expect(described_class.for(DeepOstruct.wrap(sys: { id: "e1" }, date: "soon", coordinates: { lat: 40.0, lon: -105.0 }))).to be_nil
  end

  # Each upstream call is separate: one failure gives a card with some data and does not remove
  # the widget.
  it "keeps the presenter when one upstream call fails" do
    allow(weather).to receive(:data).and_raise("WeatherKit is away")

    expect(described_class.for(event)).to be_a(EventWeatherPresenter)
    expect(EventWeatherPresenter).to have_received(:new).with(satisfy { |record| record.weather.nil? }, goodspeed: nil)
  end

  it "reads the bay conditions for a race in San Francisco only" do
    described_class.for(event)
    expect(Goodspeed).not_to have_received(:new)

    allow_any_instance_of(described_class).to receive(:in_san_francisco?).and_return(true)
    described_class.for(event)
    expect(Goodspeed).to have_received(:new).once
    expect(EventWeatherPresenter).to have_received(:new).with(anything, goodspeed: goodspeed.data)
  end
end
