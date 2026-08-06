require "openssl"
require "base64"

# Verifies Whoop webhook requests: X-WHOOP-Signature is a base64 HMAC-SHA256 of the timestamp
# plus the raw body, keyed on the OAuth client secret, and the accompanying timestamp is bounded
# to limit replay.
# @see https://developer.whoop.com/docs/developing/webhooks/
module WhoopRequestVerification
  extend ActiveSupport::Concern

  # Clock skew tolerated in either direction — Whoop's docs promise no clock discipline.
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

  # @param timestamp [String] Milliseconds since the epoch.
  # @return [Boolean] Whether it's numeric and within the skew window.
  def fresh_timestamp?(timestamp)
    ms = Float(timestamp)
    (Time.now.to_f * 1000 - ms).abs <= MAX_TIMESTAMP_SKEW.in_milliseconds
  rescue ArgumentError, TypeError
    false
  end
end
