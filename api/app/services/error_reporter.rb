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

  # Guards the lazy definition of the per-service UpstreamError subclasses (see
  # exception_class_for) so concurrent Puma threads don't race on the first const_set.
  EXCEPTION_MUTEX = Mutex.new

  # Reports a handled upstream-API failure to Bugsnag at "warning" severity (kept distinct
  # from the genuine unhandled crashes that surface as "error"). A no-op outside production,
  # since Bugsnag's notify_release_stages is limited to production and BUGSNAG_API_KEY is
  # unset locally/in CI. Never raises into the caller — error reporting must not break the
  # request path.
  #
  # Non-2xx responses (passed as a "HTTP <code>" string) are wrapped in a per-service
  # UpstreamError subclass — e.g. GoogleAirQualityError — so the failing service is visible
  # in the Bugsnag/Slack headline at a glance instead of being buried in metadata. The
  # service and context also drive Bugsnag's context label and grouping_hash, so distinct
  # services/contexts/statuses form their own groups rather than all collapsing under this
  # one notify call site.
  #
  # @param error [Exception, String] The rescued exception, or a message for a non-2xx
  #   response (which isn't an exception).
  # @param service [String] The reporting service class/module name.
  # @param context [String, nil] Optional label for what was being attempted.
  # @param status [Integer, nil] The upstream HTTP status code, when applicable.
  # @param url [String, nil] The upstream URL; sanitized to host+path before reporting.
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

  # Builds the exception handed to Bugsnag. Real rescued exceptions pass through unchanged —
  # their actual class (Net::ReadTimeout, JSON::ParserError, …) and backtrace are more useful
  # than a generic wrapper. A non-exception message (a non-2xx response) is wrapped in the
  # per-service UpstreamError subclass, with the context appended so the cause and where it
  # happened both read off the headline (e.g. "HTTP 400 — Api::EventsController#event_weather_for").
  #
  # @param error [Exception, String]
  # @param service [String]
  # @param context [String, nil]
  # @return [Exception]
  def build_exception(error, service:, context:)
    return error if error.is_a?(Exception)

    message = context.present? ? "#{error} — #{context}" : error.to_s
    exception_class_for(service).new(message)
  end

  # Returns (lazily defining, once) the UpstreamError subclass for a service — e.g.
  # "GoogleAirQuality" → ErrorReporter::GoogleAirQualityError. Subclassing UpstreamError keeps
  # existing `rescue ErrorReporter::UpstreamError` and Bugsnag's group-by-class behavior intact.
  # Falls back to the bare UpstreamError when the service name has no usable characters.
  #
  # @param service [String]
  # @return [Class]
  def exception_class_for(service)
    base = service.to_s.gsub(/[^A-Za-z0-9]/, "")
    return UpstreamError if base.blank?

    name = "#{base}Error"
    EXCEPTION_MUTEX.synchronize do
      const_defined?(name, false) ? const_get(name, false) : const_set(name, Class.new(UpstreamError))
    end
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

  # Stable, greppable base class for the non-exception (non-2xx response) reports so they
  # group together in Bugsnag rather than scattering across ad-hoc RuntimeErrors. Concrete
  # reports use a per-service subclass (e.g. GoogleAirQualityError), defined lazily by
  # exception_class_for, so the service shows in the headline while still being rescuable as
  # an UpstreamError.
  class UpstreamError < StandardError; end
end
