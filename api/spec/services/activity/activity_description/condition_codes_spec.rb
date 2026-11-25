require "rails_helper"

RSpec.describe ActivityDescription::ConditionCodes do
  it "knows the codes of config/conditions.yml" do
    expect(described_class.known?("Rain")).to be(true)
    expect(described_class.known?("SomethingNew")).to be(false)
  end

  it "gives the simplified phrase of a code, or the code as words" do
    expect(described_class.phrase("MostlyClear")).to eq("Mostly clear")
    expect(described_class.phrase("SomethingNew")).to eq("Something new")
  end

  it "writes the phrase of a fact in lower case, with no ampersand" do
    expect(described_class.fact_phrase("MixedRainAndSnow")).to eq("mixed rain and snow")
  end

  it "gives the type of precipitation of a code" do
    expect(described_class.precipitation_type("Drizzle")).to eq("rain")
    expect(described_class.precipitation_type("Haze")).to be_nil
  end

  it "knows adverse weather" do
    expect(described_class.adverse?("Haze")).to be(true)
    expect(described_class.adverse?("Clear")).to be(false)
    expect(described_class.adverse?(nil)).to be(false)
  end

  it "gives the emoji of a code, for the day or the night" do
    expect(described_class.emoji("Clear", daylight: true)).to eq("☀️")
    expect(described_class.emoji("Clear", daylight: false)).to eq("🌙")
    expect(described_class.emoji("Rain", daylight: false)).to eq("🌧️")
    expect(described_class.emoji("SomethingNew", daylight: true)).to be_nil
  end

  it "gives the sky code of a cloud cover" do
    codes = [ 0, 13, 62.9, 88, 100 ].map { |percent| described_class.for_cloud_cover(percent) }

    expect(codes).to eq(%w[Clear MostlyClear PartlyCloudy Cloudy Cloudy])
  end
end
