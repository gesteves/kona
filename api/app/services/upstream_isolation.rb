# Isolates one upstream data source: runs the block, and on a raise logs, reports, and returns
# the fallback — so a failing dependency degrades to "no data" rather than collapsing the whole
# widget into a 500. The live-update contract prefers an empty or partial fragment over an
# error.
module UpstreamIsolation
  private

  # @param service [String] The upstream being isolated, which drives Bugsnag's grouping.
  # @param fallback [Object] The value to return when the block raises.
  # @param context [String] A label for the log line and Bugsnag context.
  def safely(service = self.class.name, fallback = nil, context: self.class.name)
    yield
  rescue StandardError => e
    Rails.logger.error("#{context}: #{e}")
    ErrorReporter.report_upstream(e, service: service, context: context)
    fallback
  end
end
