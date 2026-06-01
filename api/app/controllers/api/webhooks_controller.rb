module Api
  # Receives Contentful webhooks and keeps the standard.site PDS records in sync as
  # entries are published/unpublished/deleted. The work is synchronous (no job queue):
  # a publish does one CDA fetch + at most one blob upload + one putRecord, well within
  # Contentful's 30s webhook timeout. Contentful does NOT retry failed deliveries, so the
  # standard_site:backfill rake task is the reconciliation safety net.
  #
  # Routing is driven by the X-Contentful-Topic header (the action) and the payload's
  # sys.contentType.sys.id (which content type) + sys.id (which entry). The body is never
  # trusted for entry content — the service re-fetches the resolved entry from the CDA.
  class WebhooksController < BaseController
    include ContentfulRequestVerification

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

      service = StandardSite.new
      result =
        case content_type
        when ARTICLE_TYPE
          if entry_id.present?
            action == "publish" ? service.sync_document(entry_id) : service.delete_document(entry_id)
          end
        when SITE_TYPE
          service.sync_publication if action == "publish"
        end
      # Pages and any other content type are intentionally ignored.

      Rails.logger.info("Contentful webhook handled: contentType=#{content_type} entry=#{entry_id} action=#{action} result=#{result || 'ignored'}")
      head :no_content
    rescue StandardError => e
      # Acknowledge so Contentful records a clean delivery (it won't retry either way);
      # the backfill task reconciles anything this drops.
      Rails.logger.error("Contentful webhook error: #{e.message}")
      head :no_content
    end
  end
end
