require "rails_helper"

RSpec.describe ActivityDescription::TrackWeather do
  let(:start) { Time.utc(2026, 9, 20, 12) }
  let(:weather_kit) { double("WeatherKit") }
  let(:meters_per_degree) { 6_371_000.0 * Math::PI / 180 }

  # A track along one meridian, one point each minute, with the latitude of each point.
  def track_from(latitudes)
    meters = 0.0
    latitudes.each_with_index.map do |latitude, minute|
      meters += (latitude - latitudes[minute - 1]).abs * meters_per_degree if minute.positive?
      { offset: minute * 60, latitude: latitude, longitude: -119.0, meters: meters, index: minute }
    end
  end

  # A track to the north. Each minute moves `degrees` of latitude.
  def north(minutes, degrees: 0.003) = track_from(Array.new(minutes) { |minute| 46.0 + (minute * degrees) })

  def hours(**fields)
    (0..3).map do |offset|
      {
        forecastStart: (start + offset.hours).iso8601, temperature: 10.0, temperatureApparent: 10.0,
        windSpeed: 5.0, windGust: 8.0, windDirection: 0, humidity: 0.5, precipitationIntensity: 0.0,
        conditionCode: "Clear", daylight: true
      }.merge(fields)
    end
  end

  def track_weather(points) = described_class.new(points, start: start, weather_kit: weather_kit)

  before { allow(weather_kit).to receive(:hourly).and_return(hours) }

  describe "the calls" do
    # 30 minutes at 0.003° each minute cross the cells from 46.00 to 46.09.
    it "makes one call for each cell that the track crosses" do
      weather = track_weather(north(31))
      weather.query_points

      expect(weather.calls).to eq(10)
    end

    # The first point in the cell 46.01 is at 46.006.
    it "asks for the position of the first point in each cell" do
      track_weather(north(31)).query_points

      expect(weather_kit).to have_received(:hourly).with(46.0, -119.0, any_args)
      expect(weather_kit).to have_received(:hourly).with(46.006, -119.0, any_args)
    end

    it "shares the call of a cell that the track enters again" do
      out = Array.new(31) { |minute| 46.0 + (minute * 0.003) }
      weather = track_weather(track_from(out + out.reverse.drop(1)))
      weather.query_points

      expect(weather.calls).to eq(10)
    end

    it "asks for the hours from the start hour to two hours after the hour of the end" do
      track_weather(north(61, degrees: 0.0)).query_points

      expect(weather_kit).to have_received(:hourly).with(46.0, -119.0, from: start, to: start + 3.hours).once
    end

    it "takes an even share of the cells past MAX_CALLS" do
      stub_const("#{described_class}::MAX_CALLS", 3)

      weather = track_weather(north(31))
      weather.query_points

      expect(weather.calls).to eq(3)
      expect(weather_kit).to have_received(:hourly).with(46.0, -119.0, any_args)
      expect(weather_kit).to have_received(:hourly).with(46.09, -119.0, any_args)
    end
  end

  describe "a position with no hours" do
    before { allow(weather_kit).to receive(:hourly) { |latitude, *| hours if latitude < 46.015 } }

    # ⚠️ Each call already tries again. An outage must not cost one failed call for each cell.
    it "stops the calls, and gives no weather after the last query point with hours" do
      points = north(31)
      weather = track_weather(points)

      expect(weather.at(points.first)).to include(temperature: 10.0)
      expect(weather.at(points.last)).to be_nil
      expect(weather.calls).to eq(3)
    end

    it "gives no weather at all when the first call has no hours" do
      allow(weather_kit).to receive(:hourly).and_return(nil)
      points = north(31)
      weather = track_weather(points)

      expect(weather.at(points.first)).to be_nil
      expect(weather.calls).to eq(1)
    end
  end

  # The track crosses two cells: 46.00 to minute 16, and 46.01 from minute 17 (46.0051).
  describe "the value between two query points" do
    let(:points) { north(31, degrees: 0.0003) }

    def at(minute, south:, north:)
      allow(weather_kit).to receive(:hourly) { |latitude, *| hours(**(latitude < 46.005 ? south : north)) }
      track_weather(points).at(points[minute])
    end

    def share(minute) = points[minute][:meters] / points[17][:meters]

    it "mixes the values by the share of the distance" do
      expect(at(8, south: { temperature: 10.0 }, north: { temperature: 20.0 })[:temperature]).to be_within(0.01).of(10.0 + (10.0 * share(8)))
      expect(at(8, south: { cloudCover: 0.0 }, north: { cloudCover: 1.0 })[:cloudCover]).to be_within(0.01).of(share(8))
    end

    it "mixes the wind direction across north, and not through south" do
      direction = at(8, south: { windDirection: 350 }, north: { windDirection: 10 })[:windDirection]

      expect([ direction, 360 - direction ].min).to be < 2
    end

    it "takes the condition of the nearer point" do
      expect(at(3, south: { conditionCode: "Clear" }, north: { conditionCode: "Cloudy" })[:conditionCode]).to eq("Clear")
      expect(at(14, south: { conditionCode: "Clear" }, north: { conditionCode: "Cloudy" })[:conditionCode]).to eq("Cloudy")
    end

    # A dry code with a measurable rate becomes a wet code, from the mixed rate.
    it "decides the wet code after the mix" do
      south = { conditionCode: "Cloudy", precipitationType: "rain", precipitationIntensity: 0.0 }
      north = { conditionCode: "Cloudy", precipitationType: "rain", precipitationIntensity: 0.2 }

      expect(at(8, south: south, north: north)[:conditionCode]).to eq("Drizzle")
      expect(at(2, south: south, north: north)[:conditionCode]).to eq("Cloudy")
    end
  end
end
