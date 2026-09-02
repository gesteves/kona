require "rails_helper"
require "openssl"
require "base64"

RSpec.describe "Webhooks::Whoop", type: :request do
  let(:client_secret) { "whoop-client-secret" }
  let(:whoop) { instance_double(Whoop, user_id: 12345) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WHOOP_CLIENT_SECRET").and_return(client_secret)
    allow(Whoop).to receive(:new).and_return(whoop)
    # The webhook only adds a job to the queue. Each job runs in the fake mode, thus no code here
    # calls Whoop or Intervals.icu.
  end

  def now_ms
    (Time.now.to_f * 1000).to_i
  end

  def payload(overrides = {})
    {
      "user_id" => 12345,
      "id" => "workout-uuid-1",
      "type" => "workout.updated",
      "trace_id" => "trace-1"
    }.merge(overrides)
  end

  # Posts a Whoop webhook with a signature: base64(HMAC-SHA256(timestamp + rawBody,
  # client_secret)).
  def post_webhook(body, secret: client_secret, timestamp: now_ms, signature: nil)
    body = body.to_json unless body.is_a?(String)
    signature ||= Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, timestamp.to_s + body))

    post "/webhooks/whoop",
      params: body,
      headers: {
        "Content-Type" => "application/json",
        "X-WHOOP-Signature" => signature,
        "X-WHOOP-Signature-Timestamp" => timestamp.to_s
      }
  end

  context "with a valid signature and payload" do
    # The controller keeps the id of each event for the signature window, thus each example starts
    # with no record of its event.
    before { $redis.del("whoop:webhook:workout.updated:workout-uuid-1", "whoop:webhook:recovery.updated:sleep-uuid-9") }

    # ⚠️ The signature accepts a timestamp of some minutes, and a replay inside that window must not
    # add the job again: each run makes a new description with a new text.
    it "acknowledges a repeated event and adds no second job" do
      post_webhook(payload)
      post_webhook(payload)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("ok" => true, "duplicate" => true)
      expect(WhoopWebhookJob.jobs.size).to eq(1)
    end

    it "acks with 200 {ok: true} and enqueues the processing job" do
      post_webhook(payload)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("ok" => true)
      expect(WhoopWebhookJob).to have_enqueued_sidekiq_job("workout.updated", "workout-uuid-1", "trace-1")
    end

    it "enqueues sleep and recovery events with their (sleep) UUID" do
      post_webhook(payload("type" => "recovery.updated", "id" => "sleep-uuid-9"))
      expect(response).to have_http_status(:ok)
      expect(WhoopWebhookJob).to have_enqueued_sidekiq_job("recovery.updated", "sleep-uuid-9", "trace-1")
    end
  end

  context "with an invalid signature" do
    it "rejects a tampered signature" do
      post_webhook(payload, signature: Base64.strict_encode64("nope"))
      expect(response).to have_http_status(:unauthorized)
      expect(WhoopWebhookJob.jobs).to be_empty
    end

    it "rejects a signature computed with the wrong secret" do
      post_webhook(payload, secret: "wrong-secret")
      expect(response).to have_http_status(:unauthorized)
      expect(WhoopWebhookJob.jobs).to be_empty
    end

    it "rejects when the signature headers are missing" do
      post "/webhooks/whoop", params: payload.to_json, headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
      expect(WhoopWebhookJob.jobs).to be_empty
    end
  end

  context "with a bad timestamp" do
    it "rejects a stale timestamp (older than 5 minutes)" do
      post_webhook(payload, timestamp: now_ms - 6.minutes.in_milliseconds)
      expect(response).to have_http_status(:unauthorized)
      expect(WhoopWebhookJob.jobs).to be_empty
    end

    it "rejects a future timestamp (more than 5 minutes ahead)" do
      post_webhook(payload, timestamp: now_ms + 6.minutes.in_milliseconds)
      expect(response).to have_http_status(:unauthorized)
      expect(WhoopWebhookJob.jobs).to be_empty
    end

    it "rejects a non-numeric timestamp" do
      post_webhook(payload, timestamp: "not-a-number")
      expect(response).to have_http_status(:unauthorized)
      expect(WhoopWebhookJob.jobs).to be_empty
    end
  end

  context "when the secret is not configured" do
    before { allow(ENV).to receive(:[]).with("WHOOP_CLIENT_SECRET").and_return(nil) }

    it "rejects the request" do
      post_webhook(payload)
      expect(response).to have_http_status(:unauthorized)
      expect(WhoopWebhookJob.jobs).to be_empty
    end
  end

  context "with a malformed body" do
    it "rejects invalid JSON" do
      post_webhook("{not json")
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "Invalid JSON body")
      expect(WhoopWebhookJob.jobs).to be_empty
    end

    it "rejects a payload with a non-integer user_id" do
      post_webhook(payload("user_id" => "12345"))
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "Malformed Whoop webhook payload")
      expect(WhoopWebhookJob.jobs).to be_empty
    end

    it "rejects a payload missing trace_id" do
      post_webhook(payload.except("trace_id"))
      expect(response).to have_http_status(:bad_request)
      expect(WhoopWebhookJob.jobs).to be_empty
    end
  end

  context "when the authenticated user can't be resolved" do
    before { allow(whoop).to receive(:user_id).and_raise("whoop is down") }

    it "responds 500 without enqueuing" do
      post_webhook(payload)
      expect(response).to have_http_status(:internal_server_error)
      expect(JSON.parse(response.body)).to eq("error" => "Unable to verify user identity")
      expect(WhoopWebhookJob.jobs).to be_empty
    end
  end

  context "when the payload belongs to another user" do
    it "responds 403 without enqueuing" do
      post_webhook(payload("user_id" => 99999))
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)).to eq("error" => "user_id does not match configured athlete")
      expect(WhoopWebhookJob.jobs).to be_empty
    end
  end
end
