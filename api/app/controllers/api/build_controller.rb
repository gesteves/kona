module Api
  # Triggers a rebuild + redeploy of the static web site on demand. A bearer-token-secured POST
  # enqueues a SiteBuildJob, which fires the GitHub `repository_dispatch` the "Web" workflow
  # listens for — the same mechanism a Contentful publish uses, just with its own event type so
  # the deploy notification says where it came from.
  #
  # Origin-only: the web Worker's proxy claims /api/contact explicitly, not /api/*, so this is
  # reachable at KONA_API_URL with the bearer but never from a browser on the site. Don't add it
  # to that allowlist.
  class BuildController < BaseController
    # The API_TOKEN bearer check is inherited from BaseController; only forgery protection
    # (this is a POST) needs handling here.
    skip_forgery_protection

    # A short lock so a runaway caller can't queue a pile of Actions runs: repeats inside the
    # window get a 429 instead of another dispatch. Never released explicitly — it just expires.
    #
    # ⚠️ Deliberately scoped to this endpoint. The Contentful webhook enqueues SiteBuildJob
    # directly and must not share this window: a publish arriving while the lock was held would be
    # silently dropped, leaving the site stale until something else triggered a build. A caller
    # here instead gets an explicit 429 and can retry, and bulk-publish dispatch noise is already
    # collapsed by the workflow's cancel-in-progress concurrency.
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
