require "openssl"
require "base64"

# Checks each Whoop webhook request. X-WHOOP-Signature is a base64 HMAC-SHA256 of the timestamp and
# the raw body, with the OAuth client secret as its key. The timestamp beside it has a limit, which
# stops a replay.
# @see https://developer.whoop.com/docs/developing/webhooks/
module WhoopRequestVerification
  extend ActiveSupport::Concern

  # The clock difference that the code accepts, before the time and after it. The Whoop
  # documentation says nothing about its clocks.
  MAX_TIMESTAMP_SKEW = 5.minutes

  private

  def verify_whoop_signature!
    secret = ENV["WHOOP_CLIENT_SECRET"].to_s
    return head(:unauthorized) if secret.blank?

    signature = request.headers["X-WHOOP-Signature"].to_s
    timestamp = request.headers["X-WHOOP-Signature-Timestamp"].to_s
    return head(:unauthorized) if signature.blank? || timestamp.blank?
    return head(:unauthorized) unless fresh_timestamp?(timestamp)

    expected = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, timestamp + request.raw_post))
    head(:unauthorized) unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)
  end

  # @param timestamp [String] The milliseconds after the epoch.
  # @return [Boolean] True if it is a number and it is in the window.
  def fresh_timestamp?(timestamp)
    ms = Float(timestamp)
    (Time.now.to_f * 1000 - ms).abs <= MAX_TIMESTAMP_SKEW.in_milliseconds
  rescue ArgumentError, TypeError
    false
  end
end
