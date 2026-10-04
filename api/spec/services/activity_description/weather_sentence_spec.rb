require "rails_helper"

RSpec.describe ActivityDescription::WeatherSentence do
  let(:imperial) { { temperature: "°F", wind: "mph" } }
  let(:metric) { { temperature: "°C", wind: "km/h" } }

  def sentence(**summary) = described_class.call({ units: imperial }.merge(summary))

  it "writes the condition, the wind, and the temperature" do
    expect(sentence(
      condition: "Clear", wind: { direction: "WNW", speed: { min: 3, max: 3 }, gust: 6 },
      temperature: { min: 64, max: 71 }, feels_like: { min: 62, max: 72 }
    )).to eq("Clear with WNW winds of 3 mph and 6 mph gusts, 64°F–71°F (feels like 62°F–72°F)")
  end

  it "writes no wind for a calm activity, and one temperature when the range has one value" do
    expect(sentence(condition: "Mostly clear", temperature: { min: 70, max: 70 })).to eq("Mostly clear, 70°F")
  end

  it "joins the precipitation, the wind, and the rest with a serial comma, and the headwind after the wind" do
    expect(described_class.call(
      units: metric, condition: "Cloudy", precipitation: { condition: "rain", minutes: 25 },
      wind: { direction: "SSE", speed: { min: 12, max: 18 }, gust: 24 }, headwind_percent: 62,
      temperature: { min: 11, max: 13 }, feels_like: { min: 8, max: 10 }
    )).to eq("Cloudy with 25 minutes of rain, SSE winds of 12–18 km/h and 24 km/h gusts (62% headwind), " \
             "and 11°C–13°C (feels like 8°C–10°C)")
  end

  it "writes the precipitation alone with no wind" do
    expect(sentence(condition: "Rain", precipitation: { condition: "snow", minutes: 80 }, temperature: { min: 30, max: 34 }))
      .to eq("Rain with 1 hour 20 minutes of snow, 30°F–34°F")
  end

  it "writes the top of a wind range that starts at zero" do
    expect(sentence(condition: "Clear", wind: { direction: "W", speed: { min: 0, max: 3 }, gust: 4 }, temperature: { min: 60, max: 60 }))
      .to eq("Clear with W winds of 3 mph and 4 mph gusts, 60°F")
  end

  it "writes no gusts when the summary has none" do
    expect(sentence(condition: "Clear", wind: { direction: "N", speed: { min: 3, max: 6 } }, temperature: { min: 60, max: 60 }))
      .to eq("Clear with N winds of 3–6 mph, 60°F")
  end

  it "ends with the humidity and the AQI, with a serial and" do
    expect(sentence(condition: "Haze", temperature: { min: 82, max: 88 }, humidity_percent: 78, aqi: 112))
      .to eq("Haze, 82°F–88°F, 78% humidity, and AQI 112")
  end

  it "writes a negative range with a minus sign and \"to\"" do
    expect(described_class.call(units: metric, condition: "Snow", temperature: { min: -2, max: 2 }, feels_like: { min: -9, max: -5 }))
      .to eq("Snow, −2°C to 2°C (feels like −9°C to −5°C)")
  end

  describe ".duration" do
    it "writes minutes, hours, or both" do
      expect([ 1, 25, 60, 80, 120 ].map { |minutes| described_class.duration(minutes) })
        .to eq([ "1 minute", "25 minutes", "1 hour", "1 hour 20 minutes", "2 hours" ])
    end
  end
end
