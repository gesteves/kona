require "rails_helper"

RSpec.describe "Strava webhook", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STRAVA_WEBHOOK_VERIFY_TOKEN").and_return("the-verify-token")
    $redis.set(Strava::SUBSCRIPTION_KEY, "77")
    StravaCredentials.store_athlete(
      athlete_id: 42, athlete_name: "Athlete",
      access_token: "an-access-token", refresh_token: "a-refresh-token", expires_at: 6.hours.from_now.to_i
    )
  end

  def event(**overrides)
    { object_type: "activity", object_id: 123, aspect_type: "create", owner_id: 42,
      subscription_id: 77, event_time: 1_760_000_000, updates: {} }.merge(overrides)
  end

  def post_event(body)
    post "/webhooks/strava", params: body.to_json, headers: { "Content-Type" => "application/json" }
  end

  describe "GET /webhooks/strava" do
    it "echoes the challenge for our verify token" do
      get "/webhooks/strava", params: { "hub.mode" => "subscribe", "hub.challenge" => "abc", "hub.verify_token" => "the-verify-token" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("hub.challenge" => "abc")
    end

    it "refuses another verify token" do
      get "/webhooks/strava", params: { "hub.mode" => "subscribe", "hub.challenge" => "abc", "hub.verify_token" => "nope" }

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses every token when none is configured" do
      allow(ENV).to receive(:[]).with("STRAVA_WEBHOOK_VERIFY_TOKEN").and_return(nil)

      get "/webhooks/strava", params: { "hub.mode" => "subscribe", "hub.challenge" => "abc", "hub.verify_token" => "" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /webhooks/strava" do
    it "adds the job for a new activity" do
      post_event(event)

      expect(response).to have_http_status(:ok)
      expect(StravaActivityJob).to have_enqueued_sidekiq_job("123", 1_760_000_000)
    end

    # ⚠️ Our own PUT of the name and the description makes an update event. A handler would loop.
    it "ignores an update" do
      post_event(event(aspect_type: "update", updates: { title: "New name" }))

      expect(response).to have_http_status(:ok)
      expect(StravaActivityJob.jobs).to be_empty
    end

    # ⚠️ Strava does not sign an event, thus a forged deauthorization must not remove the connection.
    it "ignores a deauthorization and keeps the connection" do
      post_event(event(object_type: "athlete", object_id: 42, aspect_type: "update", updates: { authorized: "false" }))

      expect(response).to have_http_status(:ok)
      expect(StravaCredentials.connected?).to be(true)
    end

    it "refuses an event of another athlete or another subscription" do
      post_event(event(owner_id: 99))
      expect(response).to have_http_status(:forbidden)

      post_event(event(subscription_id: 1))
      expect(response).to have_http_status(:forbidden)

      expect(StravaActivityJob.jobs).to be_empty
    end

    it "refuses each event before `rake strava:subscribe` stores the subscription" do
      $redis.del(Strava::SUBSCRIPTION_KEY)

      post_event(event)

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a body with the wrong shape" do
      post_event(event(object_id: "123"))
      expect(response).to have_http_status(:bad_request)

      post "/webhooks/strava", params: "not json", headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:bad_request)
    end
  end
end
