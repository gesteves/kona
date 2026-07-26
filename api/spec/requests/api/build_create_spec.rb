require "rails_helper"

RSpec.describe "Build", type: :request do
  let(:token) { "test-token" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("API_TOKEN").and_return(token)
  end

  it "rejects requests without a bearer token" do
    post "/api/build"
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects requests with the wrong bearer token" do
    post "/api/build", headers: { "Authorization" => "Bearer nope" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "enqueues a SiteBuildJob with the manual event type" do
    allow($redis).to receive(:set).and_return(true)

    post "/api/build", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:accepted)
    expect(SiteBuildJob).to have_enqueued_sidekiq_job("api-build")
  end

  it "takes a short lock so repeats inside the window don't queue another build" do
    expect($redis).to receive(:set).with("build:trigger_lock", "1", nx: true, ex: 60).and_return(true)

    post "/api/build", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:accepted)
  end

  it "returns 429 without enqueueing when the lock is already held" do
    allow($redis).to receive(:set).and_return(false)

    post "/api/build", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:too_many_requests)
    expect(SiteBuildJob.jobs).to be_empty
  end
end
