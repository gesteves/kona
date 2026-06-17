require "rails_helper"

RSpec.describe GoogleAirQuality do
  let(:latitude) { 40.01 }
  let(:longitude) { -105.27 }
  let(:country) { "US" }

  let(:aqi_index) do
    {
      code: "usa_epa_nowcast",
      aqi: 42,
      category: "Good air quality"
    }
  end

  let(:current_body) { { indexes: [aqi_index] }.to_json }
  let(:forecast_body) { { hourlyForecasts: [{ indexes: [aqi_index] }] }.to_json }

  before do
    # Cache always misses; writes are no-ops.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)

    allow(HTTParty).to receive(:post) do |url, **_opts|
      body = url.include?("forecast:lookup") ? forecast_body : current_body
      instance_double(HTTParty::Response, success?: true, body: body, request: nil)
    end
  end

  describe "current conditions" do
    it "hits currentConditions:lookup when no datetime is given" do
      result = described_class.new(latitude, longitude, country).aqi

      expect(result).to eq(aqi: 42, category: "Good", description: "Good air quality")
      expect(HTTParty).to have_received(:post).with(a_string_matching(%r{/currentConditions:lookup}), any_args)
    end

    it "hits currentConditions:lookup for a datetime in the past" do
      described_class.new(latitude, longitude, country, "usa_epa_nowcast", 1.hour.ago)

      expect(HTTParty).to have_received(:post).with(a_string_matching(%r{/currentConditions:lookup}), any_args)
    end
  end

  describe "forecast" do
    it "hits forecast:lookup for a datetime within the 96-hour horizon" do
      result = described_class.new(latitude, longitude, country, "usa_epa_nowcast", 2.days.from_now).aqi

      expect(result).to eq(aqi: 42, category: "Good", description: "Good air quality")
      expect(HTTParty).to have_received(:post).with(a_string_matching(%r{/forecast:lookup}), any_args)
    end

    it "does not request a forecast beyond the 96-hour horizon (the 400 regression guard)" do
      result = described_class.new(latitude, longitude, country, "usa_epa_nowcast", 5.days.from_now).aqi

      expect(result).to be_nil
      expect(HTTParty).not_to have_received(:post)
    end
  end

  it "returns nil without any request when coordinates are blank" do
    expect(described_class.new(nil, nil, country).aqi).to be_nil
    expect(HTTParty).not_to have_received(:post)
  end
end
