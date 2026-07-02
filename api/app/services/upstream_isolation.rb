# Isolates a single upstream data source: runs the block and, when it raises, logs and
# reports the failure (see ErrorReporter) and returns the fallback instead — so one failing
# dependency degrades to "no data" rather than collapsing the whole widget into a 500 (the
# live-update contract prefers an empty/partial fragment over an error). Shared by the
# service layer (ApplicationService#rescue_with) and the widget controllers that
# orchestrate several upstreams directly.
module UpstreamIsolation
  private

  # @param service [String] The upstream being isolated (drives Bugsnag's error class/grouping).
  # @param fallback [Object] The value to return when the block raises (default nil).
  # @param context [String] A label for the log line and Bugsnag context.
  def safely(service = self.class.name, fallback = nil, context: self.class.name)
    yield
  rescue StandardError => e
    Rails.logger.error("#{context}: #{e}")
    ErrorReporter.report_upstream(e, service: service, context: context)
    fallback
  end
end
