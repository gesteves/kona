module Webhooks
  # Receives Contentful webhooks and keeps the derived copies of the content in sync: the
  # standard.site PDS records, article embeddings, the R2 image mirror, and the static site.
  # The request only enqueues jobs and returns 204, so slow work can't approach Contentful's
  # 30s webhook timeout and a failure is retried by Sidekiq rather than dropped. Contentful
  # doesn't retry deliveries, so the two backfill rake tasks remain the reconciliation net.
  #
  # Routing comes from the X-Contentful-Topic header plus the payload's content type and id.
  # The body is never trusted for entry content — the jobs re-fetch from the CDA.
  class ContentfulController < BaseController
    include ContentfulRequestVerification

    # Authenticated by Contentful's HMAC request signature (Contentful has no bearer token to
    # send), and hit directly by Contentful rather than through the proxy.
    before_action :verify_contentful_signature!, only: :create

    ARTICLE_TYPE = "article".freeze
    SITE_TYPE = "site".freeze
    # Assets carry no sys.contentType, so they can't be routed by content type the way entries
    # are, and the topic is the only signal stable across actions — a delete delivers a
    # DeletedAsset payload.
    ASSET_ENTITY = "Asset".freeze

    def create
      payload = JSON.parse(request.raw_post)
      content_type = payload.dig("sys", "contentType", "sys", "id")
      entry_id = payload.dig("sys", "id")
      topic = request.headers["X-Contentful-Topic"].to_s
      action = topic.split(".").last # publish, unpublish, or delete
      entity = topic.split(".")[-2]  # Entry or Asset

      Rails.logger.info("Contentful webhook received: topic=#{topic} contentType=#{content_type} entry=#{entry_id}")

      operation =
        case content_type
        when ARTICLE_TYPE
          if entry_id.present?
            action == "publish" ? "sync_document" : "delete_document"
          end
        when SITE_TYPE
          "sync_publication" if action == "publish"
        end
      # Pages and any other content type are intentionally ignored.

      StandardSiteSyncJob.perform_async(operation, entry_id) if operation

      # Keeps the related-articles widget current without a rebuild.
      if content_type == ARTICLE_TYPE && entry_id.present?
        ArticleEmbeddingJob.perform_async(action == "publish" ? "embed" : "delete", entry_id)
      end

      # ⚠️ Publish only. Unpublish and delete deliberately don't remove the object: the web
      # build reads Contentful with a preview token, so an unpublished asset is still
      # referenced by built pages and dropping it would break live images. Keys are immutable,
      # so there's nothing to invalidate; orphans are cheap and pruned by hand.
      AssetSyncJob.perform_async(entry_id) if entity == ASSET_ENTITY && action == "publish" && entry_id.present?

      # Rebuilds the static site whenever published content changes. Only these three actions
      # change the built site — a draft auto-save must not trigger a deploy.
      SiteBuildJob.perform_async if %w[publish unpublish delete].include?(action)

      Rails.logger.info("Contentful webhook handled: contentType=#{content_type} entry=#{entry_id} action=#{action} operation=#{operation || 'ignored'}")
      head :no_content
    rescue StandardError => e
      # Acknowledged anyway, since Contentful won't retry either way; a transient enqueue
      # failure is reconciled by the backfill tasks.
      Rails.logger.error("Contentful webhook error: #{e.message}")
      head :no_content
    end
  end
end
