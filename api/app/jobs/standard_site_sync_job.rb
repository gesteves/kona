# Does one standard.site PDS sync operation, outside the Contentful webhook request. You can do each
# operation more than one time: putRecord makes or updates a record, and delete does nothing for a
# record that is absent. Thus the retries from the parent class are safe. After the last attempt the
# job goes into the Dead set. standard_site:backfill is the larger reconciliation path.
class StandardSiteSyncJob < ApplicationJob
  # @param operation [String] "sync_document", "delete_document", or "sync_publication".
  # @param entry_id [String, nil] The Contentful entry id. "sync_publication" does not use it.
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
