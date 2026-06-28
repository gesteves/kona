# Runs a single standard.site PDS sync operation in the background, off the Contentful
# webhook request path. Arguments are plain strings (JSON-serializable, per Sidekiq best
# practices) and every operation is idempotent — putRecord is an upsert and delete is a
# no-op on a missing record — so the automatic retries below are safe. After the retries are
# exhausted the job lands in the Dead set (visible in the web UI); the standard_site:backfill
# task remains the broader reconciliation path.
class StandardSiteSyncJob
  include Sidekiq::Job

  sidekiq_options retry: 5

  # @param operation [String] "sync_document", "delete_document", or "sync_publication".
  # @param entry_id [String, nil] The Contentful entry id (unused for "sync_publication").
  def perform(operation, entry_id = nil)
    service = StandardSite.new
    case operation
    when "sync_document"    then service.sync_document(entry_id)
    when "delete_document"  then service.delete_document(entry_id)
    when "sync_publication" then service.sync_publication
    else
      Rails.logger.warn("StandardSiteSyncJob: unknown operation #{operation.inspect}; ignoring")
    end
  end
end
