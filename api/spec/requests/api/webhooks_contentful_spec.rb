require "rails_helper"
require "openssl"

RSpec.describe "Api::Webhooks contentful", type: :request do
  let(:webhook_secret) { "a" * 64 }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CONTENTFUL_WEBHOOK_SECRET").and_return(webhook_secret)
    # Default: stub all PDS-touching service methods so nothing hits the network.
    allow_any_instance_of(StandardSite).to receive(:sync_document)
    allow_any_instance_of(StandardSite).to receive(:delete_document)
    allow_any_instance_of(StandardSite).to receive(:sync_publication)
  end

  def now_ms
    (Time.now.to_f * 1000).to_i
  end

  # Posts a signed Contentful webhook. The canonical request signs only the timestamp
  # header (mirroring ContentfulRequestVerification#canonical_request).
  def post_webhook(payload, topic:, secret: webhook_secret, timestamp: now_ms, signature: nil)
    body = payload.to_json
    canonical = ["POST", "/api/webhooks/contentful", "x-contentful-timestamp:#{timestamp}", body].join("\n")
    signature ||= OpenSSL::HMAC.hexdigest("SHA256", secret, canonical)

    post "/api/webhooks/contentful",
      params: body,
      headers: {
        "Content-Type" => "application/json",
        "X-Contentful-Topic" => topic,
        "x-contentful-signature" => signature,
        "x-contentful-signed-headers" => "x-contentful-timestamp",
        "x-contentful-timestamp" => timestamp.to_s
      }
  end

  def entry_payload(id, content_type)
    { "sys" => { "id" => id, "contentType" => { "sys" => { "id" => content_type } } } }
  end

  context "with a valid signature" do
    it "syncs the document on an article publish" do
      expect_any_instance_of(StandardSite).to receive(:sync_document).with("entry123")
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
    end

    it "deletes the document on an article unpublish" do
      expect_any_instance_of(StandardSite).to receive(:delete_document).with("entry123")
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.unpublish")
      expect(response).to have_http_status(:no_content)
    end

    it "deletes the document on an article delete" do
      expect_any_instance_of(StandardSite).to receive(:delete_document).with("entry123")
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.delete")
      expect(response).to have_http_status(:no_content)
    end

    it "re-syncs the publication on a site publish" do
      expect_any_instance_of(StandardSite).to receive(:sync_publication)
      post_webhook(entry_payload("site1", "site"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
    end

    it "ignores other content types (e.g. page)" do
      expect_any_instance_of(StandardSite).not_to receive(:sync_document)
      expect_any_instance_of(StandardSite).not_to receive(:delete_document)
      expect_any_instance_of(StandardSite).not_to receive(:sync_publication)
      post_webhook(entry_payload("page1", "page"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
    end

    it "logs receipt and the dispatched result" do
      allow(Rails.logger).to receive(:info).and_call_original
      expect(Rails.logger).to receive(:info).with(/Contentful webhook received.*contentType=article entry=entry123/)
      expect(Rails.logger).to receive(:info).with(/Contentful webhook handled.*entry=entry123 action=publish/)

      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
    end

    it "acknowledges (204) even if the service raises" do
      allow_any_instance_of(StandardSite).to receive(:sync_document).and_raise("boom")
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
    end
  end

  context "with a bad signature" do
    it "rejects a tampered signature" do
      expect_any_instance_of(StandardSite).not_to receive(:sync_document)
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish", signature: "deadbeef")
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a signature computed with the wrong secret" do
      expect_any_instance_of(StandardSite).not_to receive(:sync_document)
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish", secret: "b" * 64)
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a stale timestamp even with an otherwise-valid signature" do
      expect_any_instance_of(StandardSite).not_to receive(:sync_document)
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish", timestamp: now_ms - 60_000)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context "when the secret is not configured" do
    before { allow(ENV).to receive(:[]).with("CONTENTFUL_WEBHOOK_SECRET").and_return(nil) }

    it "rejects the request" do
      expect_any_instance_of(StandardSite).not_to receive(:sync_document)
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
