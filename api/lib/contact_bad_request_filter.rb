# A Bugsnag callback that removes the BadRequest that Rails raises when the body of a contact-form
# submission is not correct UTF-8. A spam bot that posts cp1251 text does this often, and a browser
# never does. Rails checks the encoding while it makes the params hash, thus it raises from
# Instrumentation#process_action. That is outside the controller, and thus before the honeypot, the
# length limits, Turnstile, and Akismet. The app adds no job to the queue and the sender already gets
# a 400. Only the report stays, and nobody can act on it.
#
# ⚠️ This applies to POST /api/contact only, on purpose. That is the one endpoint that takes any
# input directly from the internet. A BadRequest on a webhook or on a widget means that a caller that
# we control sends incorrect data, and that must continue to give a report.
#
# ⚠️ This cannot be a `rescue_from` in the controller. ActionController::Base includes Instrumentation
# *after* Rescue, thus its process_action is around the rescue chain, and the raise goes to
# ShowExceptions before a handler runs.
class ContactBadRequestFilter
  # @param report [Bugsnag::Report] The report that Bugsnag is ready to send.
  # @return [Boolean] False to remove the report, and true to send it.
  def self.call(report)
    return true unless report.original_error.is_a?(ActionController::BadRequest)

    env = report.request_data[:rack_env]
    return true if env.blank?

    !(env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"] == "/api/contact")
  end
end
