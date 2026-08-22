module Api
  # Builds the static web site again and deploys it, when a caller asks. It adds the same
  # SiteBuildJob to the queue that a Contentful publish uses, with its own event type. Thus the
  # deploy notification names the cause.
  #
  # ⚠️ This is on the origin only. The proxy of the web Worker takes /api/contact and not /api/*.
  # Thus a caller with the bearer token can reach this path, and a browser never can. Do not add it
  # to that list.
  class BuildController < BaseController
    skip_forgery_protection

    # A short lock, thus a caller that sends many requests cannot start many Actions runs. A second
    # request in that time gets a 429. The code never removes the lock: it expires.
    #
    # ⚠️ This applies to this endpoint only, on purpose. The Contentful webhook adds SiteBuildJob to
    # the queue itself, and it must not share this window. If it did, a publish during the lock
    # would go away with no message, and the site would be old.
    BUILD_LOCK_KEY = "build:trigger_lock".freeze
    BUILD_LOCK_TTL = 60.seconds

    def create
      unless $redis.set(BUILD_LOCK_KEY, "1", nx: true, ex: BUILD_LOCK_TTL.to_i)
        return render json: { error: "A build was already triggered in the last #{BUILD_LOCK_TTL.to_i} seconds" },
          status: :too_many_requests
      end

      SiteBuildJob.perform_async(SiteBuildJob::MANUAL_EVENT_TYPE)
      # This is a 202, and not a 204: the build is in the queue and it is not complete.
      head :accepted
    end
  end
end
