module Webhooks
  # Takes the Strava webhook events. A new activity starts the description of that activity.
  #
  # ⚠️ Strava does not sign an event. Thus the code accepts only the events of our subscription and
  # of the connected athlete, and it uses only the id and the time of the event: the job reads each
  # other value from Intervals.icu. A forged event can then only start the description of one of our
  # own activities again.
  #
  # ⚠️ Strava waits 2 seconds for the answer, thus this only adds a job to the queue.
  # @see https://developers.strava.com/docs/webhooks/
  class StravaController < BaseController
    # GET /webhooks/strava — the challenge that Strava sends when `rake strava:subscribe` makes the
    # subscription.
    def show
      expected = ENV["STRAVA_WEBHOOK_VERIFY_TOKEN"].to_s
      unless params["hub.mode"] == "subscribe" && expected.present? &&
             ActiveSupport::SecurityUtils.secure_compare(params["hub.verify_token"].to_s, expected)
        return head :forbidden
      end

      render json: { "hub.challenge" => params["hub.challenge"] }
    end

    # POST /webhooks/strava
    def create
      event = parse_event
      return head :bad_request if event.nil?
      return head :forbidden unless ours?(event)

      # ⚠️ A `create` only. Our own PUT of the name and the description makes an `update` event, and
      # a handler of that event would loop. An `athlete` event is ignored too: a forged
      # deauthorization would remove the connection, and a true one shows on the Connected apps
      # card at the next token refresh.
      if event["object_type"] == "activity" && event["aspect_type"] == "create"
        Rails.logger.info("Strava webhook: new activity #{event['object_id']}")
        StravaActivityJob.perform_async(event["object_id"].to_s, event["event_time"])
      end

      head :ok
    end

    private

    # @return [Hash, nil] The event, or nil for a body that is not JSON or that has the wrong shape.
    def parse_event
      event = JSON.parse(request.raw_post)
      return unless event.is_a?(Hash)
      return unless %w[object_id owner_id subscription_id event_time].all? { |key| event[key].is_a?(Integer) }
      return unless event["object_type"].is_a?(String) && event["aspect_type"].is_a?(String)

      event
    rescue JSON::ParserError
      nil
    end

    # @return [Boolean] True for an event of our subscription and of the connected athlete.
    def ours?(event)
      subscription_id = Strava.subscription_id
      athlete_id = StravaCredentials.fetch.athlete_id

      subscription_id.present? && athlete_id.present? &&
        event["subscription_id"].to_s == subscription_id &&
        event["owner_id"].to_s == athlete_id
    end
  end
end
