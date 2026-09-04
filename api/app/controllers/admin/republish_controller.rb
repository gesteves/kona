module Admin
  # Builds and deploys the static web site again, from the Republish dialog of the nav. That dialog
  # is in the admin layout, thus each admin page can start a build.
  #
  # There is no page here, and there is no GET. The nav item opens the dialog, and the dialog posts
  # to this one action.
  class RepublishController < BaseController
    # The limits of the delay, in minutes. The dialog writes them into the number input, and this
    # action checks them again, because a client can send any value.
    # ⚠️ A delay of zero is "now", and it is the default. The dialog has no separate control for it:
    # the label of the submit button is what says which one the value gives.
    MIN_MINUTES = 0
    MAX_MINUTES = 60
    DEFAULT_MINUTES = 0

    # POST /republish
    def create
      minutes = delay_minutes
      return refuse(t("admin.republish.toast.out_of_range", min: MIN_MINUTES, max: MAX_MINUTES)) if minutes.nil?
      return build_now if minutes.zero?

      replaced = SiteBuildJob.schedule_in(minutes.minutes, SiteBuildJob::ADMIN_EVENT_TYPE)
      key = replaced ? "rescheduled" : "scheduled"
      accept(t("admin.republish.toast.#{key}", count: minutes))
    end

    private

    # Adds an immediate build to the queue, or says that one already started.
    #
    # The lock is the same one that POST /api/build takes. Thus a double click, and a click after a
    # curl, cannot start two Actions runs.
    #
    # ⚠️ It takes the lock before it cancels the scheduled build. In the other order, a click inside
    # the window of the lock would cancel that build and start nothing.
    def build_now
      unless SiteBuildJob.claim_trigger_lock
        seconds = SiteBuildJob::TRIGGER_LOCK_TTL.to_i
        return refuse(t("admin.republish.toast.already_started", count: seconds))
      end

      cancelled = SiteBuildJob.cancel_scheduled
      SiteBuildJob.perform_async(SiteBuildJob::ADMIN_EVENT_TYPE)
      accept(t("admin.republish.toast.#{cancelled ? "now_cancelled" : "now"}"))
    end

    # Reads the delay of the form.
    #
    # ⚠️ It matches the digits before it converts. `to_i` gives 0 for text, and 0 is "now", thus a
    # value with a mistake would start a build.
    # @return [Integer, nil] The number of minutes, or nil when the value is outside the limits.
    def delay_minutes
      value = params[:minutes].to_s.strip
      return nil unless value.match?(/\A\d+\z/)

      minutes = value.to_i
      minutes.between?(MIN_MINUTES, MAX_MINUTES) ? minutes : nil
    end

    # @param message [String] The words of the toast.
    def accept(message)
      render json: { message: message }
    end

    # @param message [String] The words of the toast.
    def refuse(message)
      render json: { message: message }, status: :unprocessable_content
    end
  end
end
