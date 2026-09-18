require "rails_helper"

RSpec.describe GooglePollen do
  subject(:service) { described_class.new(40.0, -105.0, 2) }

  let(:body) do
    { dailyInfo: [ { pollenTypeInfo: [ { code: "GRASS", indexInfo: { value: 3, category: "Moderate" } } ] } ] }.to_json
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GOOGLE_API_KEY").and_return("api-key")
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
    allow(HTTParty).to receive(:get).and_return(instance_double(HTTParty::Response, success?: true, body: body, request: nil))
  end

  it "asks the forecast endpoint for the days at the coordinates, with the shared API key" do
    service.data

    expect(HTTParty).to have_received(:get).with(
      "#{GooglePollen::GOOGLE_POLLEN_API_URL}/forecast:lookup",
      query: { "location.latitude": 40.0, "location.longitude": -105.0, days: 2, plantsDescription: 0, languageCode: "en", key: "api-key" }
    )
  end

  it "gives the forecast with snake_case keys and dot access" do
    expect(service.data.daily_info.first.pollen_type_info.first.index_info.category).to eq("Moderate")
  end

  it "gives nil and makes no request with no coordinates" do
    expect(described_class.new(nil, nil).data).to be_nil
    expect(HTTParty).not_to have_received(:get)
  end

  it "gives nil when the service fails" do
    allow(HTTParty).to receive(:get).and_return(instance_double(HTTParty::Response, success?: false, code: 500, body: "", request: nil))
    allow(ErrorReporter).to receive(:report_upstream)

    expect(service.data).to be_nil
  end
end
