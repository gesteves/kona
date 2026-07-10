require "openssl"
require "base64"

# Verifies Whoop webhook requests using Whoop's HMAC scheme. Whoop signs each request with
# the app's OAuth client secret and sends two headers:
#   - X-WHOOP-Signature            base64( HMAC-SHA256( timestamp + rawBody, client_secret ) )
#   - X-WHOOP-Signature-Timestamp  ms-since-epoch when the request was signed
# The timestamp is bounded to ±5 minutes of clock skew to limit replay.
# @see https://developer.whoop.com/docs/developing/webhooks/
module WhoopRequestVerification
  extend ActiveSupport::Concern

  # Maximum clock skew tolerated between Whoop's signing timestamp and ours — past OR
  # future (Whoop's docs don't promise clock discipline, so both directions are bounded).
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

  # @param timestamp [String] ms-since-epoch.
  # @return [Boolean] true when numeric and within the skew window in either direction.
  def fresh_timestamp?(timestamp)
    ms = Float(timestamp)
    (Time.now.to_f * 1000 - ms).abs <= MAX_TIMESTAMP_SKEW.in_milliseconds
  rescue ArgumentError, TypeError
    false
  end
end
