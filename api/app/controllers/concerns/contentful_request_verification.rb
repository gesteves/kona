require "openssl"

# Verifies Contentful webhook requests against their HMAC signature, which Contentful computes
# with CONTENTFUL_WEBHOOK_SECRET over the canonical request and sends in x-contentful-signature,
# alongside x-contentful-signed-headers and x-contentful-timestamp.
# @see https://www.contentful.com/developers/docs/webhooks/request-verification/
module ContentfulRequestVerification
  extend ActiveSupport::Concern

  # Bounds replay by rejecting timestamps older than this, or in the future. Matches
  # Contentful's own default.
  TIMESTAMP_TTL = 30_000 # milliseconds

  private

  def verify_contentful_signature!
    secret = ENV["CONTENTFUL_WEBHOOK_SECRET"].to_s
    return head(:unauthorized) if secret.blank?

    signature = request.headers["x-contentful-signature"].to_s
    signed_headers = request.headers["x-contentful-signed-headers"].to_s
    timestamp = request.headers["x-contentful-timestamp"].to_s
    return head(:unauthorized) if signature.blank? || timestamp.blank?
    return head(:unauthorized) unless fresh_timestamp?(timestamp)

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, canonical_request(signed_headers))
    head(:unauthorized) unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)
  end

  # @param timestamp [String] Milliseconds since the epoch.
  # @return [Boolean] Whether it's within the replay window and not future-dated.
  def fresh_timestamp?(timestamp)
    age = (Time.now.to_f * 1000) - timestamp.to_i
    age >= 0 && age <= TIMESTAMP_TTL
  end

  # Rebuilds the exact string Contentful signed: method, path, the signed headers, and the raw
  # body, newline-joined. Uses the verbatim request bytes, never re-serialized params, so the
  # digest matches.
  # @param signed_headers [String] The comma-separated header names to include.
  # @return [String]
  def canonical_request(signed_headers)
    headers = signed_headers.split(",").map(&:strip).reject(&:blank?).map do |name|
      "#{name.downcase}:#{request.headers[name]}"
    end.join(";")

    [request.request_method, request.fullpath, headers, request.raw_post].join("\n")
  end
end
