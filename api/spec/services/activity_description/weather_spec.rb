require "rails_helper"

RSpec.describe ActivityDescription::Weather do
  let(:start) { Time.utc(2026, 9, 20, 12) }
  let(:activity) { { start_date: start.iso8601 } }
  let(:weather_kit) { double("WeatherKit") }
  let(:air_quality) { double("GoogleAirQuality", history: nil) }

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
      conditionCode: "Clear", daylight: true
    }.merge(fields)
  end

  def weather(streams, unit: :celsius, headwind: true)
    described_class.new(activity, streams, unit: unit, headwind: headwind, weather_kit: weather_kit, air_quality: air_quality)
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

  # The wind comes from the north.
  it "gives the headwind share of a course into the wind" do
    expect(summary(streams_for(north(30)))[:headwind_percent]).to eq(100)
  end

  it "omits a headwind below HEADWIND_MIN_PERCENT" do
    expect(summary(streams_for(south(30)))).not_to have_key(:headwind_percent)
  end

  it "gives the highest gust, only when it is more than the top of the wind range" do
    allow(weather_kit).to receive(:hourly).and_return([ hour(0, windGust: 20.0), hour(1, windGust: 30.0), hour(2, windGust: 30.0) ])
    expect(summary(streams_for(north(61)))[:wind][:gust]).to eq(30)

    allow(weather_kit).to receive(:hourly).and_return((0..2).map { |offset| hour(offset, windGust: 10.0) })
    expect(summary(streams_for(north(61)))[:wind]).not_to have_key(:gust)
  end

  it "gives no wind at all when it rounds to zero" do
    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset, windSpeed: 0.4, windGust: 3.0) })

    expect(summary(streams_for(north(61)))).not_to have_key(:wind)
  end

  it "omits the headwind when the mean wind is below HEADWIND_MIN_KPH" do
    allow(weather_kit).to receive(:hourly).and_return((0..3).map { |offset| hour(offset, windSpeed: 5.0) })

    expect(summary(streams_for(north(30) + south(30)))).not_to have_key(:headwind_percent)
  end

  it "measures no headwind unless the caller asks for it" do
    expect(summary(streams_for(north(30)), headwind: false)).not_to have_key(:headwind_percent)
    expect(described_class.new(activity, streams_for(north(30)), unit: :celsius, weather_kit: weather_kit, air_quality: air_quality).summary)
      .not_to have_key(:headwind_percent)
  end

  it "converts to °F and mph for an athlete who uses Fahrenheit" do
    result = summary(streams_for(north(61)), unit: :fahrenheit)

    expect(result[:units]).to eq(temperature: "°F", wind: "mph")
    expect(result[:temperature]).to eq(min: 50.0, max: 50.0)
    expect(result[:wind][:speed]).to eq(min: 6, max: 6)
  end

  describe "the precipitation" do
    # 150 minutes: about 90 minutes of the first condition, then about 60 of the second.
    def spell(first, second)
      allow(weather_kit).to receive(:hourly).and_return(
        [ hour(0, conditionCode: first), hour(1, conditionCode: first), hour(2, conditionCode: second), hour(3, conditionCode: second) ]
      )
      summary(streams_for(north(150)))
    end

    it "gives the time of precipitation during part of the activity" do
      result = spell("Cloudy", "Rain")

      expect(result[:condition]).to eq("Cloudy")
      expect(result[:precipitation]).to include(condition: "rain", minutes: be_within(10).of(60))
    end

    it "gives a precipitation of another type than the main condition" do
      expect(spell("Rain", "Snow")[:precipitation]).to include(condition: "snow")
    end

    # ⚠️ Not "Rain with 60 minutes of heavy rain": the two are one type.
    it "says nothing about a precipitation of the same type" do
      result = spell("Rain", "HeavyRain")

      expect(result[:condition]).to eq("Rain")
      expect(result).not_to have_key(:precipitation)
    end

    it "says nothing about the dry part of a wet activity" do
      expect(spell("Rain", "Cloudy")).not_to have_key(:precipitation)
    end

    # ⚠️ Haze is adverse weather, and it is not precipitation.
    it "does not count haze, wind, or smoke as precipitation" do
      expect(spell("Clear", "Haze")).not_to have_key(:precipitation)
    end
  end

  describe "the air quality" do
    it "gives the highest AQI of the start, the middle, and the end" do
      allow(air_quality).to receive(:history) { |_lat, _lon, time| { 0 => 30, 30 => 80, 60 => 50 }[((time - start) / 60).round] }

      expect(summary(streams_for(north(61)))[:aqi]).to eq(80)
      expect(air_quality).to have_received(:history).with(46.0, -119.0, start)
      expect(air_quality).to have_received(:history).exactly(3).times
    end

    it "gives a low AQI too" do
      allow(air_quality).to receive(:history).and_return(12)

      expect(summary(streams_for(north(61)))[:aqi]).to eq(12)
    end

    it "loses only the point that fails" do
      allow(ErrorReporter).to receive(:report_upstream)
      calls = 0
      allow(air_quality).to receive(:history) { (calls += 1) == 2 ? raise("timeout") : 40 }

      expect(summary(streams_for(north(61)))[:aqi]).to eq(40)
    end

    it "gives no AQI with no reading" do
      expect(summary(streams_for(north(61)))).not_to have_key(:aqi)
    end
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

    result = described_class.new({ start_date: (start + 26.minutes).iso8601 }, streams, unit: :celsius, weather_kit: weather_kit, air_quality: air_quality).summary

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
  # WeatherKit has no data, for example for an activity older than its history.
  describe "the Intervals.icu fallback" do
    # 1 PM in Richland, Washington.
    let(:day) { Time.utc(2026, 9, 20, 20) }
    let(:intervals_weather) do
      {
        has_weather: true, min_weather_temp: 17.2, max_weather_temp: 21.2, min_feels_like: 13.6, max_feels_like: 18.0,
        average_wind_speed: 3.0, average_wind_gust: 5.0, prevailing_wind_deg: 22, headwind_percent: 62.4,
        average_clouds: 0, max_rain: 0.0, max_snow: 0.0
      }
    end

    before { allow(weather_kit).to receive(:hourly).and_return(nil) }

    def fallback(at: day, streams: streams_for(north(30)), headwind: false, **fields)
      described_class.new(
        { start_date: at.iso8601 }.merge(intervals_weather).merge(fields), streams,
        unit: :fahrenheit, headwind: headwind, weather_kit: weather_kit, air_quality: air_quality
      )
    end

    it "uses the raw weather of the activity, with no humidity and no time of precipitation" do
      allow(air_quality).to receive(:history).and_return(39)

      expect(fallback.summary).to eq(
        units: { temperature: "°F", wind: "mph" }, condition: "Clear",
        temperature: { min: 63, max: 70 }, feels_like: { min: 56, max: 64 },
        wind: { direction: "NNE", speed: { min: 7, max: 7 }, gust: 11 }, aqi: 39
      )
      expect(fallback.emoji).to eq("☀️")
    end

    it "derives the condition from the rain, the snow, and the cloud cover" do
      expect(fallback(max_rain: 0.4).summary[:condition]).to eq("Rain")
      expect(fallback(max_snow: 0.2).summary[:condition]).to eq("Snow")
      expect(fallback(max_rain: 0.4, max_snow: 0.2).summary[:condition]).to eq("Mixed rain & snow")
      expect([ 5, 20, 50, 70, 95 ].map { |clouds| fallback(average_clouds: clouds).summary[:condition] })
        .to eq([ "Clear", "Mostly clear", "Partly cloudy", "Mostly cloudy", "Cloudy" ])
    end

    it "gives the night emoji after sunset" do
      # 1 AM in Richland, Washington.
      expect(fallback(at: Time.utc(2026, 9, 20, 8)).emoji).to eq("🌙")
    end

    it "gives the headwind of a bike ride from HEADWIND_MIN_PERCENT" do
      expect(fallback(headwind: true).summary[:headwind_percent]).to eq(62)
      expect(fallback(headwind_percent: 37.4, headwind: true).summary).not_to have_key(:headwind_percent)
      expect(fallback.summary).not_to have_key(:headwind_percent)
    end

    it "gives no wind when the average rounds to zero" do
      expect(fallback(average_wind_speed: 0.1).summary).not_to have_key(:wind)
    end

    # ⚠️ No GPS track means no WeatherKit, thus no weather from Intervals.icu either.
    it "gives nil with no GPS track" do
      expect(fallback(streams: []).summary).to be_nil
    end

    it "gives nil when Intervals.icu has no weather either" do
      expect(fallback(has_weather: false).summary).to be_nil
    end
  end
end
