module Admin
  # Builds and deploys the static web site again, from the Republish dialog of the nav. That dialog
  # is in the admin layout, thus each admin page can start a build.
  #
  # There is no page here, and there is no GET. The nav item opens the dialog, and the dialog posts
  # to this one action.
  class RepublishController < BaseController
    # The furthest time in the future that this action accepts. It is a guard against a year with a
    # mistake: `2062` would park a job in Redis for decades.
    MAX_HORIZON = 90.days

    # The canonical values that <wa-date-input> and <wa-time-input> submit.
    # ⚠️ The code matches these shapes before it parses. `Time#parse` is permissive: it reads
    # "not-a-date 06:30" as 06:30 today, and that time has passed, thus a build would start.
    DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
    TIME_PATTERN = /\A\d{2}:\d{2}(:\d{2})?\z/

    # POST /republish
    def create
      return build_now(notice: "Republishing the site now.") unless params[:schedule] == "later"

      at, error = scheduled_at
      return redirect_with(alert: error) if error

      # ⚠️ A time that has passed is not an error. The dialog can stay open: the owner picks a time
      # one minute away, and then submits two minutes later. To refuse it makes that person type
      # the time again for the build that they already asked for.
      return build_now(notice: "That time had passed, so the site is republishing now.") unless at.future?

      SiteBuildJob.perform_at(at, SiteBuildJob::ADMIN_EVENT_TYPE)
      redirect_with(notice: "Republish scheduled for #{at.strftime('%-d %B %Y at %-l:%M %p %Z')}.")
    end

    private

    # Adds an immediate build to the queue, or says that one already started.
    #
    # The lock is the same one that POST /api/build takes. Thus a double click, and a click after a
    # curl, cannot start two Actions runs.
    # @param notice [String] The message for a build that starts.
    def build_now(notice:)
      unless SiteBuildJob.claim_trigger_lock
        seconds = SiteBuildJob::TRIGGER_LOCK_TTL.to_i
        return redirect_with(alert: "A republish already started in the last #{seconds} seconds.")
      end

      SiteBuildJob.perform_async(SiteBuildJob::ADMIN_EVENT_TYPE)
      redirect_with(notice: notice)
    end

    # Reads the date and the time of the form in the zone of the browser.
    # @return [Array(ActiveSupport::TimeWithZone, nil), Array(nil, String)] The time, or the reason
    #   that the code refuses it.
    def scheduled_at
      date = params[:date].to_s.strip
      time = params[:time].to_s.strip
      return [ nil, "Pick a date and a time." ] if date.blank? || time.blank?

      return [ nil, "That date and time are not valid." ] unless date.match?(DATE_PATTERN) && time.match?(TIME_PATTERN)

      at = time_zone.parse("#{date} #{time}")
      return [ nil, "That date and time are not valid." ] if at.nil?
      return [ nil, "Pick a time in the next #{MAX_HORIZON.inspect}." ] if at > MAX_HORIZON.from_now

      [ at, nil ]
    rescue ArgumentError, Date::Error
      [ nil, "That date and time are not valid." ]
    end

    # The zone of the browser, which the dialog sends in a hidden field.
    #
    # ⚠️ This app declares no `config.time_zone`, thus the fallback is UTC. The fallback applies
    # only when the field is absent, which means that the script did not run.
    # @return [ActiveSupport::TimeZone]
    def time_zone
      ActiveSupport::TimeZone[params[:time_zone].to_s] || Time.zone
    end

    # Goes back to the page that holds the dialog, because the nav is on each admin page.
    def redirect_with(**flash_options)
      redirect_back_or_to root_path, status: :see_other, **flash_options
    end
  end
end
