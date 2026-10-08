require "rails_helper"

RSpec.describe ActivityDescription::WeatherSentence do
  let(:imperial) { { temperature: "°F", wind: "mph" } }
  let(:metric) { { temperature: "°C", wind: "km/h" } }

  def sentence(**summary) = described_class.call({ units: imperial }.merge(summary))

  it "writes the condition, the temperature, and the wind, with a middot between them" do
    expect(sentence(
      condition: "Clear", wind: { direction: "WNW", speed: { min: 3, max: 3 }, gust: 6 },
      temperature: { min: 64, max: 71 }, feels_like: { min: 62, max: 72 }
    )).to eq("Clear · 64°F–71°F (feels like 62°F–72°F) · 3 mph WNW wind with 6 mph gusts")
  end

  it "writes the phrase of the LLM in place of the condition and the precipitation" do
    summary = { units: { temperature: "°C", wind: "km/h" }, condition: "Cloudy", precipitation: { condition: "rain" },
                temperature: { min: 11, max: 13 } }

    expect(described_class.call(summary, "Cloudy, then rain")).to eq("Cloudy, then rain · 11°C–13°C")
    expect(described_class.call(summary, nil)).to eq("Cloudy with some rain · 11°C–13°C")
  end

  it "starts with the temperature when the summary has no condition" do
    expect(described_class.call(units: { temperature: "°C", wind: "km/h" }, temperature: { min: 11, max: 13 })).to eq("11°C–13°C")
  end

  it "writes no wind for a calm activity, and one temperature when the range has one value" do
    expect(sentence(condition: "Mostly clear", temperature: { min: 70, max: 70 })).to eq("Mostly clear · 70°F")
  end

  it "keeps the precipitation with the condition, and the headwind after the wind" do
    expect(described_class.call(
      units: metric, condition: "Cloudy", precipitation: { condition: "rain" },
      wind: { direction: "SSE", speed: { min: 12, max: 18 }, gust: 24 }, headwind_percent: 62,
      temperature: { min: 11, max: 13 }, feels_like: { min: 8, max: 10 }
    )).to eq("Cloudy with some rain · 11°C–13°C (feels like 8°C–10°C) · " \
             "12–18 km/h SSE wind with 24 km/h gusts (62% headwind)")
  end

  it "writes the precipitation with no time" do
    expect(sentence(condition: "Rain", precipitation: { condition: "snow" }, temperature: { min: 30, max: 34 }))
      .to eq("Rain with some snow · 30°F–34°F")
  end

  it "writes the top of a wind range that starts at zero" do
    expect(sentence(condition: "Clear", wind: { direction: "W", speed: { min: 0, max: 3 }, gust: 4 }, temperature: { min: 60, max: 60 }))
      .to eq("Clear · 60°F · 3 mph W wind with 4 mph gusts")
  end

  it "writes no gusts when the summary has none" do
    expect(sentence(condition: "Clear", wind: { direction: "N", speed: { min: 3, max: 6 } }, temperature: { min: 60, max: 60 }))
      .to eq("Clear · 60°F · 3–6 mph N wind")
  end

  it "puts the humidity after the temperature, and the AQI at the end" do
    expect(sentence(
      condition: "Mostly clear", temperature: { min: 82, max: 88 }, feels_like: { min: 90, max: 95 }, humidity_percent: 78,
      wind: { direction: "W", speed: { min: 5, max: 8 } }, aqi: 42
    )).to eq("Mostly clear · 82°F–88°F (feels like 90°F–95°F) · 78% humidity · 5–8 mph W wind · AQI 42")
  end

  it "writes a negative range with a minus sign and \"to\"" do
    expect(described_class.call(units: metric, condition: "Snow", temperature: { min: -2, max: 2 }, feels_like: { min: -9, max: -5 }))
      .to eq("Snow · −2°C to 2°C (feels like −9°C to −5°C)")
  end
end
