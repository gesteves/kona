require "openssl"

# Verifies Contentful webhook requests using Contentful's HMAC request-verification
# scheme. Contentful signs each request with the shared CONTENTFUL_WEBHOOK_SECRET and
# sends three headers:
#   - x-contentful-signature       the HMAC-SHA256 hex digest of the canonical request
#   - x-contentful-signed-headers  comma-separated names of the headers in the signature
#   - x-contentful-timestamp       ms-since-epoch when the request was signed (replay TTL)
# The canonical request is method + path + the signed headers (lowercased name:value,
# semicolon-joined) + the raw body, joined by newlines.
# @see https://www.contentful.com/developers/docs/webhooks/request-verification/
module ContentfulRequestVerification
  extend ActiveSupport::Concern

  # Reject requests whose signing timestamp is older than this (or in the future),
  # bounding replay. Matches Contentful's default verification TTL.
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

  # @param timestamp [String] ms-since-epoch.
  # @return [Boolean] true if within the replay window and not future-dated.
  def fresh_timestamp?(timestamp)
    age = (Time.now.to_f * 1000) - timestamp.to_i
    age >= 0 && age <= TIMESTAMP_TTL
  end

  # Rebuilds the exact string Contentful signed. Uses request.raw_post (the verbatim
  # bytes) — never re-serialized params — so the digest matches.
  # @param signed_headers [String] the comma-separated header names from the header.
  # @return [String]
  def canonical_request(signed_headers)
    headers = signed_headers.split(",").map(&:strip).reject(&:blank?).map do |name|
      "#{name.downcase}:#{request.headers[name]}"
    end.join(";")

    [request.request_method, request.fullpath, headers, request.raw_post].join("\n")
  end
end
