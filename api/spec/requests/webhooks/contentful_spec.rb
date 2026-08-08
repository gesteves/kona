require "rails_helper"
require "openssl"

RSpec.describe "Webhooks::Contentful", type: :request do
  let(:webhook_secret) { "a" * 64 }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CONTENTFUL_WEBHOOK_SECRET").and_return(webhook_secret)
    # The webhook only enqueues; jobs run in fake mode, so nothing touches the PDS here.
  end

  def now_ms
    (Time.now.to_f * 1000).to_i
  end

  # Posts a signed Contentful webhook. The canonical request signs only the timestamp
  # header (mirroring ContentfulRequestVerification#canonical_request).
  def post_webhook(payload, topic:, secret: webhook_secret, timestamp: now_ms, signature: nil)
    body = payload.to_json
    canonical = [ "POST", "/webhooks/contentful", "x-contentful-timestamp:#{timestamp}", body ].join("\n")
    signature ||= OpenSSL::HMAC.hexdigest("SHA256", secret, canonical)

    post "/webhooks/contentful",
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
    it "enqueues a document sync and an embedding refresh on an article publish" do
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
      expect(StandardSiteSyncJob).to have_enqueued_sidekiq_job("sync_document", "entry123")
      expect(ArticleEmbeddingJob).to have_enqueued_sidekiq_job("embed", "entry123")
    end

    it "enqueues a document delete and an embedding delete on an article unpublish" do
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.unpublish")
      expect(response).to have_http_status(:no_content)
      expect(StandardSiteSyncJob).to have_enqueued_sidekiq_job("delete_document", "entry123")
      expect(ArticleEmbeddingJob).to have_enqueued_sidekiq_job("delete", "entry123")
    end

    it "enqueues a document delete on an article delete" do
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.delete")
      expect(response).to have_http_status(:no_content)
      expect(StandardSiteSyncJob).to have_enqueued_sidekiq_job("delete_document", "entry123")
    end

    it "enqueues a publication sync on a site publish" do
      post_webhook(entry_payload("site1", "site"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
      expect(StandardSiteSyncJob).to have_enqueued_sidekiq_job("sync_publication", "site1")
    end

    it "ignores other content types (e.g. page)" do
      post_webhook(entry_payload("page1", "page"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
      expect(StandardSiteSyncJob.jobs).to be_empty
      expect(ArticleEmbeddingJob.jobs).to be_empty
    end

    it "does not enqueue an embedding refresh for a site publish" do
      post_webhook(entry_payload("site1", "site"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
      expect(ArticleEmbeddingJob.jobs).to be_empty
    end

    it "logs receipt and the dispatched operation" do
      allow(Rails.logger).to receive(:info).and_call_original
      expect(Rails.logger).to receive(:info).with(/Contentful webhook received.*contentType=article entry=entry123/)
      expect(Rails.logger).to receive(:info).with(/Contentful webhook handled.*entry=entry123 action=publish operation=sync_document/)

      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
    end

    it "acknowledges (204) even if enqueuing raises" do
      allow(StandardSiteSyncJob).to receive(:perform_async).and_raise("boom")
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:no_content)
    end

    describe "R2 image mirror (AssetSyncJob)" do
      def asset_payload(id) = { "sys" => { "id" => id, "type" => "Asset" } }

      # Assets carry no sys.contentType, so they're routed by the topic's entity segment.
      it "enqueues a mirror job on an asset publish" do
        post_webhook(asset_payload("asset1"), topic: "ContentManagement.Asset.publish")
        expect(response).to have_http_status(:no_content)
        expect(AssetSyncJob).to have_enqueued_sidekiq_job("asset1")
      end

      # ⚠️ Load-bearing. The web build reads Contentful with a preview token, so an unpublished
      # asset is still referenced by built pages — removing its object would break live images.
      it "does not touch the mirror on an asset unpublish or delete" do
        %w[unpublish delete].each do |action|
          AssetSyncJob.clear
          post_webhook(asset_payload("asset1"), topic: "ContentManagement.Asset.#{action}")
          expect(response).to have_http_status(:no_content)
          expect(AssetSyncJob.jobs).to be_empty
        end
      end

      it "does not enqueue a mirror job for entries" do
        post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish")
        expect(AssetSyncJob.jobs).to be_empty
      end

      it "does not enqueue a mirror job on a draft auto_save" do
        post_webhook(asset_payload("asset1"), topic: "ContentManagement.Asset.auto_save")
        expect(AssetSyncJob.jobs).to be_empty
      end
    end

    describe "web rebuild trigger (SiteBuildJob)" do
      it "enqueues a rebuild on publish, unpublish, and delete of any content type" do
        %w[publish unpublish delete].each do |action|
          SiteBuildJob.clear
          post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.#{action}")
          expect(response).to have_http_status(:no_content)
          expect(SiteBuildJob).to have_enqueued_sidekiq_job
        end
      end

      it "enqueues a rebuild for content types standard.site ignores (e.g. page)" do
        post_webhook(entry_payload("page1", "page"), topic: "ContentManagement.Entry.publish")
        expect(SiteBuildJob).to have_enqueued_sidekiq_job
        expect(StandardSiteSyncJob.jobs).to be_empty
      end

      it "enqueues a rebuild on an asset publish (no contentType)" do
        post_webhook({ "sys" => { "id" => "asset1", "type" => "Asset" } }, topic: "ContentManagement.Asset.publish")
        expect(response).to have_http_status(:no_content)
        expect(SiteBuildJob).to have_enqueued_sidekiq_job
      end

      it "does not enqueue a rebuild on a draft auto_save" do
        post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.auto_save")
        expect(SiteBuildJob.jobs).to be_empty
      end
    end
  end

  context "with a bad signature" do
    it "rejects a tampered signature" do
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish", signature: "deadbeef")
      expect(response).to have_http_status(:unauthorized)
      expect(StandardSiteSyncJob.jobs).to be_empty
    end

    it "rejects a signature computed with the wrong secret" do
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish", secret: "b" * 64)
      expect(response).to have_http_status(:unauthorized)
      expect(StandardSiteSyncJob.jobs).to be_empty
    end

    it "rejects a stale timestamp even with an otherwise-valid signature" do
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish", timestamp: now_ms - 60_000)
      expect(response).to have_http_status(:unauthorized)
      expect(StandardSiteSyncJob.jobs).to be_empty
    end
  end

  context "when the secret is not configured" do
    before { allow(ENV).to receive(:[]).with("CONTENTFUL_WEBHOOK_SECRET").and_return(nil) }

    it "rejects the request" do
      post_webhook(entry_payload("entry123", "article"), topic: "ContentManagement.Entry.publish")
      expect(response).to have_http_status(:unauthorized)
      expect(StandardSiteSyncJob.jobs).to be_empty
    end
  end
end
