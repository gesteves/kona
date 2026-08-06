module Webhooks
  # Receives Whoop v2 webhooks and syncs them to Intervals.icu. The request path only verifies
  # and enqueues, so the response beats Whoop's ~1s ack expectation: the HMAC proves the payload
  # came from Whoop, and its user_id is checked against the authenticated athlete so a foreign
  # user gets a 403 and Whoop stops retrying. That id is Redis-cached for a day, keeping the
  # warm path free of upstream calls.
  #
  # Responds 401 for a bad signature or stale timestamp, 400 for a malformed payload, 500 when
  # the identity check fails, 403 for a foreign user, and 200 on acceptance.
  class WhoopController < BaseController
    include WhoopRequestVerification

    # Authenticated by Whoop's HMAC signature (Whoop has no bearer token to send), and hit
    # directly by Whoop rather than through the proxy.
    before_action :verify_whoop_signature!, only: :create

    def create
      payload = parse_payload
      return render(json: { error: "Invalid JSON body" }, status: :bad_request) if payload.nil?
      return render(json: { error: "Malformed Whoop webhook payload" }, status: :bad_request) unless valid_payload?(payload)

      expected_user_id = fetch_expected_user_id
      return render(json: { error: "Unable to verify user identity" }, status: :internal_server_error) if expected_user_id.nil?

      unless payload["user_id"] == expected_user_id
        Rails.logger.warn(
          "Whoop webhook: rejecting event for user_id=#{payload['user_id']} " \
          "(expected #{expected_user_id}, type=#{payload['type']}, trace=#{payload['trace_id']})"
        )
        return render(json: { error: "user_id does not match configured athlete" }, status: :forbidden)
      end

      Rails.logger.info("Whoop webhook received: #{payload['type']} (id=#{payload['id']}, trace=#{payload['trace_id']})")
      WhoopWebhookJob.perform_async(payload["type"], payload["id"], payload["trace_id"])
      render json: { ok: true }
    end

    private

    def parse_payload
      JSON.parse(request.raw_post)
    rescue JSON::ParserError
      nil
    end

    # The HMAC has already proven the body came from Whoop, but wrong types on the required
    # fields are still rejected before the user_id comparison.
    def valid_payload?(payload)
      payload.is_a?(Hash) &&
        payload["user_id"].is_a?(Integer) &&
        payload["id"].is_a?(String) &&
        payload["type"].is_a?(String) &&
        payload["trace_id"].is_a?(String)
    end

    # @return [Integer, nil] The authenticated Whoop user's id, or nil when unresolvable —
    #   which the caller renders as a 500 so Whoop retries the delivery.
    def fetch_expected_user_id
      Whoop.new.user_id
    rescue StandardError => e
      Rails.logger.error("Whoop webhook: failed to resolve authenticated Whoop user_id: #{e.message}")
      nil
    end
  end
end
