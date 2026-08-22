module Webhooks
  # Takes the Contentful webhooks and syncs each copy of the content: the standard.site PDS
  # records, the article embeddings, the R2 image mirror, and the static site.
  # The request only adds jobs to the queue and returns 204. Thus slow work cannot reach the 30s
  # webhook timeout of Contentful, and Sidekiq does a failed job again and does not remove it.
  # Contentful does not send a delivery again, thus the two backfill rake tasks are the
  # reconciliation net.
  #
  # The X-Contentful-Topic header, with the content type and the id in the payload, decide the
  # route. The code never uses the body as the content of the entry: each job gets that from the
  # CDA.
  class ContentfulController < BaseController
    include ContentfulRequestVerification

    # The HMAC request signature of Contentful authenticates this, because Contentful can send no
    # bearer token. Contentful sends the request directly, and not through the proxy.
    before_action :verify_contentful_signature!, only: :create

    ARTICLE_TYPE = "article".freeze
    SITE_TYPE = "site".freeze
    # An asset has no sys.contentType, thus the code cannot use the content type for it, as it does
    # for an entry. The topic is the only value that is the same for each action: a delete sends a
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
      # The code ignores a Page and each other content type, on purpose.

      StandardSiteSyncJob.perform_async(operation, entry_id) if operation

      # The vector that the build uses to make the list of related articles.
      if content_type == ARTICLE_TYPE && entry_id.present?
        ArticleEmbeddingJob.perform_async(action == "publish" ? "embed" : "delete", entry_id)
      end

      # ⚠️ This is for a publish only. An unpublish and a delete do not remove the object, on
      # purpose: the web build reads Contentful with a preview token, thus a page from the build
      # still points at an unpublished asset, and a delete would break a live image. Each key is
      # immutable, thus there is nothing to invalidate. An object that nothing uses is cheap, and a
      # person removes it.
      AssetSyncJob.perform_async(entry_id) if entity == ASSET_ENTITY && action == "publish" && entry_id.present?

      # Builds the static site again at each change to the published content. Only these three
      # actions change the site from the build: an automatic save of a draft must not start a
      # deploy.
      SiteBuildJob.perform_async if %w[publish unpublish delete].include?(action)

      Rails.logger.info("Contentful webhook handled: contentType=#{content_type} entry=#{entry_id} action=#{action} operation=#{operation || 'ignored'}")
      head :no_content
    rescue StandardError => e
      # The code answers with a success, because Contentful does not send the webhook again in
      # either condition. The backfill tasks correct a temporary failure to add a job to the queue.
      # ⚠️ The code reports this and does not only write a log line: nothing here does the work
      # again. Thus a failure with no report means no new build, no embedding, and no PDS sync, and
      # a log line is the only record.
      Rails.logger.error("Contentful webhook error: #{e.message}")
      ErrorReporter.report_upstream(e, service: "ContentfulWebhook", context: "contentType=#{content_type} entry=#{entry_id} action=#{action}")
      head :no_content
    end
  end
end
