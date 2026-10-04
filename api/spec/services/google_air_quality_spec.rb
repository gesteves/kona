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

  let(:current_body) { { indexes: [ aqi_index ] }.to_json }
  let(:forecast_body) { { hourlyForecasts: [ { indexes: [ aqi_index ] } ] }.to_json }

  before do
    # The cache always gives a miss, and each write does nothing.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)

    allow(HTTParty).to receive(:post) do |url, **_opts|
      body = url.include?("forecast:lookup") ? forecast_body : current_body
      instance_double(HTTParty::Response, success?: true, body: body, request: nil)
    end
  end

  describe ".history" do
    let(:hour) { 3.days.ago.utc.beginning_of_hour }

    before do
      allow(GoogleMaps).to receive(:new).with(latitude, longitude).and_return(instance_double(GoogleMaps, country_code: country))
      allow(HTTParty).to receive(:post).and_return(
        instance_double(HTTParty::Response, success?: true, body: { hoursInfo: [ { indexes: [ aqi_index ] } ] }.to_json, request: nil)
      )
    end

    it "gives the AQI of the hour of a past time" do
      expect(described_class.history(latitude, longitude, hour + 25.minutes)).to eq(42)
      expect(HTTParty).to have_received(:post).with(
        a_string_ending_with("history:lookup"),
        hash_including(body: a_string_including(%("dateTime":"#{hour.iso8601}")))
      )
    end

    it "asks nothing for an hour older than the 30 days that Google keeps" do
      expect(described_class.history(latitude, longitude, 31.days.ago)).to be_nil
      expect(HTTParty).not_to have_received(:post)
    end

    it "asks nothing for a location with no country" do
      allow(GoogleMaps).to receive(:new).and_return(instance_double(GoogleMaps, country_code: nil))

      expect(described_class.history(latitude, longitude, hour)).to be_nil
      expect(HTTParty).not_to have_received(:post)
    end
  end

  describe "current conditions" do
    it "hits currentConditions:lookup when no datetime is given" do
      result = described_class.new(latitude, longitude, country).aqi

      expect(result).to eq(aqi: 42, category: "Good", description: "Good air quality")
      expect(HTTParty).to have_received(:post).with(a_string_matching(%r{/currentConditions:lookup}), any_args)
    end

    it "hits currentConditions:lookup for a datetime in the past" do
      described_class.new(latitude, longitude, country, "usa_epa_nowcast", 1.hour.ago).aqi

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
