require "uri"

# Reports *handled* upstream-API failures to Bugsnag. The service layer degrades gracefully, so
# none of these ever reach a controller and Bugsnag's auto-instrumentation never sees them; this
# makes them visible without changing that behavior.
module ErrorReporter
  module_function

  # Reports a handled failure at "warning" severity, keeping it distinct from the genuine
  # unhandled crashes that surface as "error". Never raises into the caller, and a no-op
  # outside production. The service and context drive the grouping_hash, so distinct failures
  # form their own Bugsnag groups rather than collapsing under this one call site.
  # @param error [Exception, String] The rescued exception, or a message for a non-2xx
  #   response, which isn't one.
  # @param service [String] The reporting service's name.
  # @param context [String, nil] What was being attempted.
  # @param status [Integer, nil] The upstream HTTP status.
  # @param url [String, nil] The upstream URL, sanitized before reporting.
  def report_upstream(error, service:, context: nil, status: nil, url: nil)
    exception = build_exception(error, service: service, context: context)
    Bugsnag.notify(exception) do |report|
      report.severity = "warning"
      report.context = [service, context].compact.join(" · ").presence
      report.grouping_hash = [service, context, status || exception.class.name].compact.join(":")
      report.add_metadata(:upstream, {
        service: service,
        context: context,
        status: status,
        url: sanitize_url(url)
      }.compact)
    end
  rescue StandardError => e
    Rails.logger.error("ErrorReporter: failed to notify Bugsnag: #{e}")
  end

  # Builds the exception handed to Bugsnag. Rescued exceptions pass through unchanged, since
  # their real class and backtrace beat a generic wrapper; a non-2xx message is wrapped in
  # UpstreamError with the service and context folded into it, so the headline reads
  # "GoogleAirQuality: HTTP 400 — Widgets::EventsController#event_weather_for".
  # @param error [Exception, String] The exception or message.
  # @param service [String] The reporting service's name.
  # @param context [String, nil] What was being attempted.
  # @return [Exception]
  def build_exception(error, service:, context:)
    return error if error.is_a?(Exception)

    detail = context.present? ? "#{error} — #{context}" : error.to_s
    UpstreamError.new("#{service}: #{detail}")
  end

  # Reduces a URL to scheme, host, and path.
  # ⚠️ The Google APIs put their API key in the query string, so the raw URL must never reach
  # Bugsnag. Request and response bodies aren't reported either, for the same reason.
  # @param url [String, nil] The URL.
  # @return [String, nil] Its sanitized form.
  def sanitize_url(url)
    return if url.blank?

    uri = URI.parse(url.to_s)
    "#{uri.scheme}://#{uri.host}#{uri.path}"
  rescue URI::InvalidURIError
    nil
  end

  # A stable class for handled non-2xx reports, so they group in Bugsnag rather than scattering
  # across ad-hoc RuntimeErrors.
  class UpstreamError < StandardError; end
end
