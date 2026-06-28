module Api
  # Receives Contentful webhooks and keeps the standard.site PDS records in sync as
  # entries are published/unpublished/deleted. The actual sync runs in the background: the
  # request only enqueues a StandardSiteSyncJob and returns 204 immediately, so a slow CDA
  # fetch / blob upload / putRecord can never approach Contentful's 30s webhook timeout, and
  # a failed sync is retried by Sidekiq instead of silently dropped. Contentful does NOT
  # retry deliveries, so the standard_site:backfill rake task remains the reconciliation net.
  #
  # Routing is driven by the X-Contentful-Topic header (the action) and the payload's
  # sys.contentType.sys.id (which content type) + sys.id (which entry). The body is never
  # trusted for entry content — the job re-fetches the resolved entry from the CDA.
  class WebhooksController < BaseController
    include ContentfulRequestVerification

    # Authenticated by Contentful's HMAC request signature, not the API_TOKEN bearer (Contentful
    # has no token to send), and hit directly by Contentful rather than through the proxy.
    skip_before_action :authenticate_bearer_token!
    skip_forgery_protection
    before_action :verify_contentful_signature!, only: :contentful

    ARTICLE_TYPE = "article".freeze
    SITE_TYPE = "site".freeze

    def contentful
      payload = JSON.parse(request.raw_post)
      content_type = payload.dig("sys", "contentType", "sys", "id")
      entry_id = payload.dig("sys", "id")
      topic = request.headers["X-Contentful-Topic"].to_s
      action = topic.split(".").last # publish | unpublish | delete

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

      Rails.logger.info("Contentful webhook handled: contentType=#{content_type} entry=#{entry_id} action=#{action} operation=#{operation || 'ignored'}")
      head :no_content
    rescue StandardError => e
      # Acknowledge so Contentful records a clean delivery (it won't retry either way); a
      # transient enqueue failure (e.g. Redis down) is reconciled by the backfill task.
      Rails.logger.error("Contentful webhook error: #{e.message}")
      head :no_content
    end
  end
end
