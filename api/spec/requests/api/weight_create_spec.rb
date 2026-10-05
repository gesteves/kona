require "rails_helper"

RSpec.describe "Weight", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:token) { "test-token" }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("API_TOKEN").and_return(token)
    allow_any_instance_of(Location).to receive(:time_zone).and_return("America/Denver")
  end

  it "rejects requests without a bearer token" do
    post "/api/weight", params: { weight: 72.4 }
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects requests with the wrong bearer token" do
    post "/api/weight", params: { weight: 72.4 }, headers: { "Authorization" => "Bearer nope" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "enqueues both syncs in kilograms for today in the time zone of the location" do
    travel_to Time.utc(2026, 10, 6, 3, 0) do
      post "/api/weight", params: { weight: 72.4 }, headers: headers
    end

    expect(response).to have_http_status(:no_content)
    expect(IntervalsWeightJob).to have_enqueued_sidekiq_job(72.4, "2026-10-05")
    expect(StravaWeightJob).to have_enqueued_sidekiq_job(72.4)
  end

  it "converts pounds to kilograms" do
    post "/api/weight", params: { weight: 160, unit: "lb", date: "2026-10-01" }, headers: headers

    expect(response).to have_http_status(:no_content)
    expect(IntervalsWeightJob).to have_enqueued_sidekiq_job(72.57, "2026-10-01")
    expect(StravaWeightJob).to have_enqueued_sidekiq_job(72.57)
  end

  {
    "a missing weight" => { unit: "kg" },
    "a non-numeric weight" => { weight: "abc" },
    "an out-of-range weight" => { weight: 5 },
    "an unknown unit" => { weight: 72.4, unit: "stone" },
    "an incorrect date" => { weight: 72.4, date: "2026-13-45" }
  }.each do |description, params|
    it "rejects #{description} and enqueues nothing" do
      post "/api/weight", params: params, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(IntervalsWeightJob.jobs).to be_empty
      expect(StravaWeightJob.jobs).to be_empty
    end
  end
end
