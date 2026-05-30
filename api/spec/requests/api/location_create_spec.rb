require "rails_helper"

RSpec.describe "Location", type: :request do
  let(:token) { "test-token" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("API_TOKEN").and_return(token)
  end

  it "rejects requests without a bearer token" do
    post "/api/location", params: { latitude: 43.48, longitude: -110.76 }
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects requests with the wrong bearer token" do
    post "/api/location",
      params: { latitude: 43.48, longitude: -110.76 },
      headers: { "Authorization" => "Bearer nope" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "stores valid coordinates in Redis" do
    expect($redis).to receive(:set).with("location:current", "43.48,-110.76")

    post "/api/location",
      params: { latitude: 43.48, longitude: -110.76 },
      headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:no_content)
  end

  it "rejects out-of-range coordinates" do
    post "/api/location",
      params: { latitude: 200, longitude: 0 },
      headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rejects missing coordinates" do
    post "/api/location",
      params: { latitude: 43.48 },
      headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:unprocessable_content)
  end
end
