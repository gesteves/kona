require "uri"

# Central place for reporting *handled* upstream-API failures to Bugsnag. The service layer
# deliberately degrades gracefully — non-2xx responses, expired tokens, rate limiting,
# timeouts, and network errors are swallowed so widgets collapse instead of crashing — which
# means none of them ever reach a controller and Bugsnag's auto-instrumentation never sees
# them. This module makes those failures visible without changing that behavior.
#
# Callable from both ApplicationService subclasses (via the report_upstream_error wrapper)
# and the FontAwesomeClient module, which is not a service object.
module ErrorReporter
  module_function

  # Reports a handled upstream-API failure to Bugsnag at "warning" severity (kept distinct
  # from the genuine unhandled crashes that surface as "error"). A no-op outside production,
  # since Bugsnag's notify_release_stages is limited to production and BUGSNAG_API_KEY is
  # unset locally/in CI. Never raises into the caller — error reporting must not break the
  # request path.
  #
  # @param error [Exception, String] The rescued exception, or a message for a non-2xx
  #   response (which isn't an exception).
  # @param service [String] The reporting service class/module name.
  # @param context [String, nil] Optional label for what was being attempted.
  # @param status [Integer, nil] The upstream HTTP status code, when applicable.
  # @param url [String, nil] The upstream URL; sanitized to host+path before reporting.
  def report_upstream(error, service:, context: nil, status: nil, url: nil)
    exception = error.is_a?(Exception) ? error : UpstreamError.new(error.to_s)
    Bugsnag.notify(exception) do |report|
      report.severity = "warning"
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

  # Reduces a URL to scheme+host+path, dropping the query string.
  #
  # ⚠️ SECURITY: the Google APIs put their API key in the query string, so the raw URL must
  # never be shipped to Bugsnag. Request/response bodies (which can hold OAuth secrets and
  # tokens) are likewise never reported — the status code, sanitized URL, and service name
  # are enough to triage.
  #
  # @param url [String, nil]
  # @return [String, nil]
  def sanitize_url(url)
    return if url.blank?

    uri = URI.parse(url.to_s)
    "#{uri.scheme}://#{uri.host}#{uri.path}"
  rescue URI::InvalidURIError
    nil
  end

  # Stable, greppable class for the non-exception (non-2xx response) reports so they group
  # together in Bugsnag rather than scattering across ad-hoc RuntimeErrors.
  class UpstreamError < StandardError; end
end
