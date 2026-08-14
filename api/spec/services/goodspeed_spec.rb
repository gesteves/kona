require "rails_helper"

RSpec.describe Goodspeed do
  subject(:service) { described_class.new }

  around do |example|
    original = ENV["GOODSPEED_API_URL"]
    ENV["GOODSPEED_API_URL"] = "https://goodspeed.test/latest.json"
    example.run
    ENV["GOODSPEED_API_URL"] = original
  end

  before do
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  it "wraps the bay conditions for dot access" do
    allow(service).to receive(:get_json).and_return(timeseries: [ { t: "2024-06-01T12:00:00Z", water_temp_c: 15.0 } ])
    expect(service.data.timeseries.first.water_temp_c).to eq(15.0)
  end

  it "returns nil when the payload has no timeseries" do
    allow(service).to receive(:get_json).and_return({})
    expect(service.data).to be_nil
  end

  it "returns nil when the fetch fails" do
    allow(service).to receive(:get_json).and_return(nil)
    expect(service.data).to be_nil
  end

  it "memoizes the result" do
    expect(service).to receive(:get_json).once.and_return(timeseries: [ { t: "2024-06-01T12:00:00Z" } ])
    2.times { service.data }
  end

  it "returns nil (and never calls the API) when the URL is unset" do
    ENV["GOODSPEED_API_URL"] = nil
    expect(service).not_to receive(:get_json)
    expect(service.data).to be_nil
  end

  it "fetches the configured URL" do
    expect(service).to receive(:get_json).with("https://goodspeed.test/latest.json").and_return(timeseries: [ { t: "2024-06-01T12:00:00Z" } ])
    service.data
  end
end
