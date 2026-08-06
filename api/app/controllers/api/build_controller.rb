module Api
  # Rebuilds and redeploys the static web site on demand, by enqueuing the same SiteBuildJob a
  # Contentful publish uses — just with its own event type, so the deploy notification names the
  # trigger.
  #
  # ⚠️ Origin-only. The web Worker's proxy claims /api/contact explicitly, not /api/*, so this
  # is reachable with the bearer but never from a browser. Don't add it to that allowlist.
  class BuildController < BaseController
    skip_forgery_protection

    # A short lock, so a runaway caller can't queue a pile of Actions runs; repeats inside the
    # window get a 429. Never released explicitly — it just expires.
    #
    # ⚠️ Deliberately scoped to this endpoint. The Contentful webhook enqueues SiteBuildJob
    # directly and must not share this window, or a publish arriving while the lock was held
    # would be silently dropped and leave the site stale.
    BUILD_LOCK_KEY = "build:trigger_lock".freeze
    BUILD_LOCK_TTL = 60.seconds

    def create
      unless $redis.set(BUILD_LOCK_KEY, "1", nx: true, ex: BUILD_LOCK_TTL.to_i)
        return render json: { error: "A build was already triggered in the last #{BUILD_LOCK_TTL.to_i} seconds" },
          status: :too_many_requests
      end

      SiteBuildJob.perform_async(SiteBuildJob::MANUAL_EVENT_TYPE)
      # 202, not 204: the build is queued, not done.
      head :accepted
    end
  end
end
