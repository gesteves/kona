require "uri"

# Sends *caught* upstream-API failures to Bugsnag. The service layer gives a smaller result on a
# failure, thus none of these failures reaches a controller and the automatic instrumentation of
# Bugsnag never sees them. This class makes them visible and does not change that behavior.
module ErrorReporter
  module_function

  # Sends a failure that the code caught, at the "warning" level. Thus it is different from a true
  # crash that nothing caught, which goes at the "error" level. It never raises into the caller, and
  # it does nothing outside production. The service and the context make the grouping_hash. Thus
  # each different failure makes its own Bugsnag group, and they do not go together under this one
  # call site.
  # @param error [Exception, String] The exception that the code caught, or a message for a non-2xx
  #   response, which is not an exception.
  # @param service [String] The name of the service that reports.
  # @param context [String, nil] The operation that failed.
  # @param status [Integer, nil] The upstream HTTP status.
  # @param url [String, nil] The upstream URL. The code removes the secret parts first.
  def report_upstream(error, service:, context: nil, status: nil, url: nil)
    exception = build_exception(error, service: service, context: context)
    Bugsnag.notify(exception) do |report|
      report.severity = "warning"
      report.context = [ service, context ].compact.join(" · ").presence
      report.grouping_hash = [ service, context, status || exception.class.name ].compact.join(":")
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

  # Makes the exception for Bugsnag. An exception that the code caught goes through with no change,
  # because its true class and its backtrace are better than a general one. A non-2xx message goes
  # into an UpstreamError with the service and the context. Thus the first line reads
  # "GoogleAirQuality: HTTP 400 — Widgets::EventsController#event_weather_for".
  # @param error [Exception, String] The exception or the message.
  # @param service [String] The name of the service that reports.
  # @param context [String, nil] The operation that failed.
  # @return [Exception]
  def build_exception(error, service:, context:)
    return error if error.is_a?(Exception)

    detail = context.present? ? "#{error} — #{context}" : error.to_s
    UpstreamError.new("#{service}: #{detail}")
  end

  # Keeps only the scheme, the host, and the path of a URL.
  # ⚠️ The Google APIs put their API key in the query string, thus the full URL must never go to
  # Bugsnag. The code also does not send a request body or a response body, for the same reason.
  # @param url [String, nil] The URL.
  # @return [String, nil] The URL with the secret parts removed.
  def sanitize_url(url)
    return if url.blank?

    uri = URI.parse(url.to_s)
    "#{uri.scheme}://#{uri.host}#{uri.path}"
  rescue URI::InvalidURIError
    nil
  end

  # One class for each non-2xx report that the code catches. Thus they make one group in Bugsnag,
  # and they are not many different RuntimeErrors.
  class UpstreamError < StandardError; end
end
