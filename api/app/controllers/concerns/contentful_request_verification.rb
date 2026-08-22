require "openssl"

# Checks each Contentful webhook request against its HMAC signature. Contentful calculates that
# signature with CONTENTFUL_WEBHOOK_SECRET over the canonical request and sends it in
# x-contentful-signature, with x-contentful-signed-headers and x-contentful-timestamp.
# @see https://www.contentful.com/developers/docs/webhooks/request-verification/
module ContentfulRequestVerification
  extend ActiveSupport::Concern

  # This limits a replay: the code refuses a timestamp that is older than this value, and a
  # timestamp in the future. It is the same as the default of Contentful.
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

  # @param timestamp [String] The milliseconds after the epoch.
  # @return [Boolean] True if it is in the replay window and it is not in the future.
  def fresh_timestamp?(timestamp)
    age = (Time.now.to_f * 1000) - timestamp.to_i
    age >= 0 && age <= TIMESTAMP_TTL
  end

  # Makes again the exact string that Contentful signed: the method, the path, the signed headers,
  # and the raw body, with a newline between them. It uses the bytes of the request, and never the
  # params after a second serialization. Thus the digest agrees.
  # @param signed_headers [String] The header names to include, with a comma between them.
  # @return [String]
  def canonical_request(signed_headers)
    headers = signed_headers.split(",").map(&:strip).reject(&:blank?).map do |name|
      "#{name.downcase}:#{request.headers[name]}"
    end.join(";")

    [ request.request_method, request.fullpath, headers, request.raw_post ].join("\n")
  end
end
