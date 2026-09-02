module Webhooks
  # Takes the Whoop v2 webhooks and syncs them to Intervals.icu. The request path only checks the
  # payload and adds a job to the queue, thus the response comes before the approximately 1s that
  # Whoop expects. The HMAC shows that the payload came from Whoop, and the code compares its
  # user_id with the authenticated athlete. Thus a different user gets a 403 and Whoop does not send
  # the webhook again. Redis holds that id for a day, thus the warm path makes no upstream call.
  #
  # It answers with a 401 for a bad signature or an old timestamp, a 400 for a payload with an
  # incorrect shape, a 500 when the identity check fails, a 403 for a different user, and a 200 when
  # it accepts the payload.
  class WhoopController < BaseController
    include WhoopRequestVerification

    # The HMAC signature of Whoop authenticates this, because Whoop can send no bearer token. Whoop
    # sends the request directly, and not through the proxy.
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

      # The signature check accepts a timestamp of some minutes, thus a replay inside that window
      # would add the job again. The job can run more than one time, but each run makes a new
      # description with a new text. This id stays for the window.
      unless $redis.set("whoop:webhook:#{payload['type']}:#{payload['id']}", "1", nx: true, ex: WhoopRequestVerification::MAX_TIMESTAMP_SKEW.to_i)
        Rails.logger.info("Whoop webhook repeated: #{payload['type']} (id=#{payload['id']})")
        return render json: { ok: true, duplicate: true }
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

    # The HMAC already shows that the body came from Whoop, but the code still refuses a necessary
    # field with an incorrect type, before the user_id comparison.
    def valid_payload?(payload)
      payload.is_a?(Hash) &&
        payload["user_id"].is_a?(Integer) &&
        payload["id"].is_a?(String) &&
        payload["type"].is_a?(String) &&
        payload["trace_id"].is_a?(String)
    end

    # @return [Integer, nil] The id of the authenticated Whoop user, or nil when the code cannot
    #   find it. The caller then gives a 500, thus Whoop sends the webhook again.
    def fetch_expected_user_id
      Whoop.new.user_id
    rescue StandardError => e
      Rails.logger.error("Whoop webhook: failed to resolve authenticated Whoop user_id: #{e.message}")
      nil
    end
  end
end
