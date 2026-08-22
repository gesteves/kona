# Separates one upstream data source: it runs the block, and on a raise it writes a log line, sends a
# report, and returns the fallback value. Thus a dependency that fails gives "no data" and does not
# make the full widget a 500. The live-update contract needs an empty fragment, or a fragment with
# some data, and not an error.
module UpstreamIsolation
  private

  # @param service [String] The upstream service. Bugsnag uses it to make its groups.
  # @param fallback [Object] The value to return when the block raises.
  # @param context [String] A label for the log line and for the Bugsnag context.
  def safely(service = self.class.name, fallback = nil, context: self.class.name)
    yield
  rescue StandardError => e
    Rails.logger.error("#{context}: #{e}")
    ErrorReporter.report_upstream(e, service: service, context: context)
    fallback
  end
end
