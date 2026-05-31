require "rails_helper"

RSpec.describe Goodspeed do
  subject(:service) { described_class.new }

  before do
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  it "wraps the bay conditions for dot access" do
    allow(service).to receive(:get_json).and_return(timeseries: [{ t: "2024-06-01T12:00:00Z", water_temp_c: 15.0 }])
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
    expect(service).to receive(:get_json).once.and_return(timeseries: [{ t: "2024-06-01T12:00:00Z" }])
    2.times { service.data }
  end
end
