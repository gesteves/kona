require "time"

# Formats the arrival time of a contact-form submission, for the email and for the Spam page.
#
# ⚠️ It gives the second, and the UTC value with the local time. An ISP needs the exact time to
# find the subscriber of an IP, and a time in an unclear zone can name the wrong one.
module SubmissionTime
  # The local part. It holds no word, thus it is not admin copy for `config/locales/en.yml`.
  LOCAL_FORMAT = "%A, %B %-e, %Y, %-I:%M:%S %p %Z".freeze

  # @param iso8601 [String, nil] The arrival time from Api::ContactController.
  # @return [String] For example "Saturday, August 1, 2026, 5:00:12 AM PDT (2026-08-01T12:00:12Z)",
  #   in the TIME_ZONE of the owner. A blank value gives the current time.
  def self.format(iso8601)
    time = iso8601.present? ? Time.iso8601(iso8601) : Time.now
    "#{time.in_time_zone(TimeZoneResolver.default).strftime(LOCAL_FORMAT)} (#{time.utc.iso8601})"
  rescue ArgumentError
    # ⚠️ A bad value gives the raw text and never a raise. A raise in ContactMailJob stops the
    # delivery.
    iso8601
  end
end
