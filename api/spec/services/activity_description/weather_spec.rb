require "rails_helper"

RSpec.describe ActivityDescription::Weather do
  let(:start) { Time.utc(2026, 9, 20, 12) }
  let(:activity) { { start_date: start.iso8601 } }
  let(:weather_kit) { double("WeatherKit") }

  # A track with one point each minute. Each step moves the given degrees of latitude and longitude.
  def streams_for(steps)
    latitude = 46.0
    longitude = -119.0
    times = []
    latitudes = []
    longitudes = []
    steps.each_with_index do |(dlat, dlon), minute|
      times << minute * 60
      latitudes << latitude
      longitudes << longitude
      latitude += dlat
      longitude += dlon
    end
    [ { type: "time", data: times }, { type: "latlng", data: latitudes, data2: longitudes } ]
  end

  def north(minutes) = Array.new(minutes) { [ 0.001, 0.0 ] }

  def south(minutes) = Array.new(minutes) { [ -0.001, 0.0 ] }

  def hour(offset, **fields)
    {
      forecastStart: (start + offset.hours).iso8601, temperature: 10.0, temperatureApparent: 10.0,
      windSpeed: 10.0, windGust: 15.0, windDirection: 0, cloudCover: 0.0, humidity: 0.5,
      precipitationIntensity: 0.0, conditionCode: "Clear", daylight: true
    }.merge(fields)
  end

  def weather(streams, unit: :celsius, headwind: true)
    described_class.new(activity, streams, unit: unit, headwind: headwind, weather_kit: weather_kit)
  end

  def summary(streams, **options) = weather(streams, **options).summary

  before do
    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset) })
  end

  it "gives nil with no GPS track" do
    expect(summary([ { type: "time", data: [ 0, 60 ] } ])).to be_nil
    expect(weather_kit).not_to have_received(:hourly)
  end

  it "asks for the hours from the start hour to two hours after the last sample" do
    summary(streams_for(north(61)))

    expect(weather_kit).to have_received(:hourly).once.with(46.0, -119.0, from: start, to: start + 3.hours)
  end

  it "interpolates between the hour before and the hour after each sample" do
    allow(weather_kit).to receive(:hourly).and_return([ hour(0, temperature: 10.0), hour(1, temperature: 20.0) ])

    # One point, 30 minutes after the start hour.
    result = described_class.new(
      { start_date: (start + 30.minutes).iso8601 }, streams_for([ [ 0, 0 ] ]), unit: :celsius, weather_kit: weather_kit
    ).summary

    expect(result[:temperature]).to eq(min: 15.0, max: 15.0)
  end

  it "interpolates the wind direction across north, and not through south" do
    allow(weather_kit).to receive(:hourly).and_return([ hour(0, windDirection: 350), hour(1, windDirection: 10) ])

    result = described_class.new(
      { start_date: (start + 30.minutes).iso8601 }, streams_for([ [ 0, 0 ] ]), unit: :celsius, weather_kit: weather_kit
    ).summary

    expect(result[:wind][:direction]).to eq("N")
  end

  it "gives the headwind share for an out-and-back course" do
    # The wind comes from the north: the way out is into the wind and the way back is not.
    result = summary(streams_for(north(30) + south(30)))

    expect(result[:headwind_percent]).to be_between(40, 60)
  end

  it "marks a wind that rounds to zero as calm, with no direction and no range" do
    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset, windSpeed: 0.4, windGust: 3.0) })

    expect(summary(streams_for(north(61)))[:wind]).to eq(calm: true, gust_max: 3)
  end

  it "omits the headwind when the mean wind is below HEADWIND_MIN_KPH" do
    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset, windSpeed: 5.0) })

    expect(summary(streams_for(north(30) + south(30)))).not_to have_key(:headwind_percent)
  end

  it "omits the headwind for a swim" do
    expect(summary(streams_for(north(30)), headwind: false)).not_to have_key(:headwind_percent)
  end

  it "converts to °F, mph, and inches for an athlete who uses Fahrenheit" do
    allow(weather_kit).to receive(:hourly).and_return(
      (0..2).map { |offset| hour(offset, precipitationIntensity: 25.4) }
    )

    result = summary(streams_for(north(61)), unit: :fahrenheit)

    expect(result[:units]).to eq(temperature: "°F", wind: "mph", precipitation: "in")
    expect(result[:temperature]).to eq(min: 50.0, max: 50.0)
    expect(result[:wind][:speed]).to eq(min: 6, max: 6)
    expect(result[:precipitation]).to eq(total: 1.0, percent_of_time: 100)
  end

  it "gives the conditions in time order" do
    allow(weather_kit).to receive(:hourly).and_return(
      [ hour(0), hour(1), hour(2, conditionCode: "Rain"), hour(3, conditionCode: "Rain") ]
    )

    result = summary(streams_for(north(150)))

    expect(result[:conditions].map { |entry| entry[:condition] }).to eq(%w[Clear Rain])
    expect(result[:conditions].first[:from_minute]).to eq(0)
    expect(result[:conditions].last[:to_minute]).to eq(149)
  end

  it "omits feels like when it rounds to the same range as the temperature" do
    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset, temperatureApparent: 10.3) })

    expect(summary(streams_for(north(61)))).not_to have_key(:feels_like)
  end

  it "gives the humidity only when it is high in warm weather" do
    expect(summary(streams_for(north(61)))).not_to have_key(:humidity_percent)

    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset, temperature: 30.0, humidity: 0.8) })
    expect(summary(streams_for(north(61)))[:humidity_percent]).to eq(80)
  end

  it "omits the conditions when the weather does not change between adverse and not adverse" do
    allow(weather_kit).to receive(:hourly).and_return(
      [ hour(0), hour(1), hour(2, conditionCode: "MostlyClear"), hour(3, conditionCode: "MostlyClear") ]
    )

    expect(summary(streams_for(north(150)))).not_to have_key(:conditions)
  end

  it "joins the next conditions on the same side of a change, and names each group by its longest one" do
    allow(weather_kit).to receive(:hourly).and_return(
      [ hour(0), hour(1, conditionCode: "MostlyClear"), hour(2, conditionCode: "MostlyClear"), hour(3, conditionCode: "Rain"), hour(4, conditionCode: "Rain") ]
    )

    result = summary(streams_for(north(240)))

    expect(result[:conditions].map { |entry| entry[:condition] }).to eq([ "Mostly clear", "Rain" ])
  end

  it "names the condition with the most time, with the phrase of config/conditions.yml" do
    allow(weather_kit).to receive(:hourly).and_return(
      [ hour(0, conditionCode: "MostlyCloudy"), hour(1, conditionCode: "MostlyCloudy"), hour(2, conditionCode: "Rain"), hour(3) ]
    )

    expect(summary(streams_for(north(100)))[:condition]).to eq("Mostly cloudy")
  end

  # A swim track can have a long GPS gap, thus each run is short and the conditions join them.
  it "names the main condition from the joined runs, and not from the raw samples" do
    allow(weather_kit).to receive(:hourly).and_return([ hour(0, conditionCode: "MostlyClear"), hour(1), hour(2) ])
    streams = [ { type: "time", data: [ 0, 1649, 1659 ] }, { type: "latlng", data: [ 46.0, 46.0, 46.0 ], data2: [ -119.0, -119.0, -119.0 ] } ]

    result = described_class.new({ start_date: (start + 26.minutes).iso8601 }, streams, unit: :celsius, weather_kit: weather_kit).summary

    expect(result[:condition]).to eq("Mostly clear")
  end

  it "gives the day emoji of the main condition in daylight, and the night emoji after dark" do
    expect(weather(streams_for(north(61))).emoji).to eq("☀️")

    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset, daylight: false) })
    expect(weather(streams_for(north(61))).emoji).to eq("🌙")
  end

  it "gives the one emoji of a condition with no day and night variants" do
    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset, conditionCode: "Rain") })

    expect(weather(streams_for(north(61))).emoji).to eq("🌧️")
  end

  it "gives no emoji for a condition that config/conditions.yml does not have" do
    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset, conditionCode: "Unknown") })

    result = weather(streams_for(north(61)))
    expect(result.emoji).to be_nil
    expect(result.summary[:condition]).to eq("Unknown")
  end

  it "keeps the number of WeatherKit calls at MAX_AREAS on a long route" do
    # Approximately 500 km to the north.
    summary(streams_for(Array.new(300) { [ 0.015, 0.0 ] }))

    expect(weather_kit).to have_received(:hourly).at_most(described_class::MAX_AREAS).times
  end

  it "gives nil when WeatherKit has no data" do
    allow(weather_kit).to receive(:hourly).and_return(nil)

    expect(summary(streams_for(north(30)))).to be_nil
  end
end
