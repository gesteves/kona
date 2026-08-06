# Runs one standard.site PDS sync operation off the Contentful webhook request path. Every
# operation is idempotent — putRecord is an upsert, delete no-ops on a missing record — so the
# inherited retries are safe. Exhausted retries land in the Dead set; standard_site:backfill is
# the broader reconciliation path.
class StandardSiteSyncJob < ApplicationJob
  # @param operation [String] "sync_document", "delete_document", or "sync_publication".
  # @param entry_id [String, nil] The Contentful entry id; unused for "sync_publication".
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
