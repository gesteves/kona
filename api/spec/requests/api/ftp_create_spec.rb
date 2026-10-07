require "rails_helper"

RSpec.describe "FTP", type: :request do
  let(:token) { "test-token" }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("API_TOKEN").and_return(token)
  end

  it "rejects requests without a bearer token" do
    post "/api/ftp", params: { ftp: 265 }
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects requests with the wrong bearer token" do
    post "/api/ftp", params: { ftp: 265 }, headers: { "Authorization" => "Bearer nope" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "enqueues both syncs in whole watts" do
    post "/api/ftp", params: { ftp: "264.6" }, headers: headers

    expect(response).to have_http_status(:no_content)
    expect(IntervalsFtpJob).to have_enqueued_sidekiq_job(265)
    expect(StravaFtpJob).to have_enqueued_sidekiq_job(265)
  end

  it "accepts a JSON body" do
    post "/api/ftp", params: { ftp: 265 }.to_json, headers: headers.merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:no_content)
    expect(IntervalsFtpJob).to have_enqueued_sidekiq_job(265)
  end

  {
    "a missing FTP" => {},
    "a non-numeric FTP" => { ftp: "abc" },
    "an out-of-range FTP" => { ftp: 5000 }
  }.each do |description, params|
    it "rejects #{description} and enqueues nothing" do
      post "/api/ftp", params: params, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(IntervalsFtpJob.jobs).to be_empty
      expect(StravaFtpJob.jobs).to be_empty
    end
  end
end
