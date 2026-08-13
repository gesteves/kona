# Bugsnag callback that drops the BadRequest raised when a contact-form submission's body isn't
# valid UTF-8, which spam bots posting cp1251-encoded text do routinely and a browser never does.
# Rails validates the encoding while building the params hash, so it raises from
# Instrumentation#process_action — outside the controller, and therefore ahead of the honeypot,
# the length caps, Turnstile, and Akismet. Nothing is enqueued and the sender already gets a 400;
# the report is the only thing left to suppress, and it isn't actionable.
#
# ⚠️ Scoped to POST /api/contact deliberately. That's the one endpoint taking arbitrary input
# straight off the internet; a BadRequest on a webhook or a widget means a caller we control
# started sending garbage, and must keep reporting.
#
# ⚠️ It can't be a `rescue_from` in the controller: ActionController::Base includes Instrumentation
# *after* Rescue, so its process_action wraps the rescue chain and the raise escapes to
# ShowExceptions before any handler runs.
class ContactBadRequestFilter
  # @param report [Bugsnag::Report] The report about to be delivered.
  # @return [Boolean] false to drop the report, true to let it through.
  def self.call(report)
    return true unless report.original_error.is_a?(ActionController::BadRequest)

    env = report.request_data[:rack_env]
    return true if env.blank?

    !(env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"] == "/api/contact")
  end
end
