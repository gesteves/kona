require "sidekiq/api"

# Builds the web site again and deploys it. It sends a GitHub `repository_dispatch`, and
# .github/workflows/web.yml waits for that event. There are three callers, and each one has its own
# event type: the Contentful webhook, POST /api/build, and the Republish dialog of the admin. They
# build in the same way. The types let the Slack notification of the deploy name the cause.
#
# A publish of many entries sends more than one event, and the cancel-in-progress concurrency of the
# workflow makes them one build. This job does nothing when there is no configuration, and it raises
# on a non-2xx, thus Sidekiq does it again.
class SiteBuildJob < ApplicationJob
  DISPATCH_URL = "https://api.github.com/repos/%<repo>s/dispatches".freeze
  # ⚠️ The `repository_dispatch.types` of .github/workflows/web.yml must contain all three. If
  # not, GitHub accepts the event with a 204 and runs nothing, and it gives no message. The event
  # type is always a constant from the caller, and never a request parameter.
  CONTENTFUL_EVENT_TYPE = "contentful-publish".freeze
  MANUAL_EVENT_TYPE = "api-build".freeze
  ADMIN_EVENT_TYPE = "admin-republish".freeze
  # The GitHub answers that no retry can correct: a token that expired or that cannot reach the
  # repo gives a 401 or a 404. ⚠️ A 403 is not here, because GitHub also gives a 403 for a rate
  # limit.
  PERMANENT_STATUSES = [ 401, 404, 422 ].freeze

  # The window that stops a second "build now" from a person. The code never removes the lock: it
  # expires.
  TRIGGER_LOCK_KEY = "build:trigger_lock".freeze
  TRIGGER_LOCK_TTL = 60.seconds

  # The jid of the republish that is scheduled. The admin keeps one only, thus each new republish
  # cancels the one before it.
  SCHEDULED_JID_KEY = "build:scheduled_jid".freeze

  # Takes the "build now" lock. The two manual callers share it, thus a double click, or a click
  # after a curl, cannot start two Actions runs.
  #
  # ⚠️ The Contentful webhook must never call this. A publish inside the window would go away with
  # no message, and the site would stay old.
  # @return [Boolean] true when this caller took the lock.
  def self.claim_trigger_lock
    !!$redis.set(TRIGGER_LOCK_KEY, "1", nx: true, ex: TRIGGER_LOCK_TTL.to_i)
  end

  # The window that makes a burst of asset publishes one build. The media uploader sends one
  # publish for each image. Without the window, each one starts a workflow run, and
  # `cancel-in-progress` in web.yml then stops all but the last. Those runs cost Actions minutes
  # and write a Slack line each.
  ASSET_WINDOW_KEY = "build:asset_window".freeze
  ASSET_WINDOW = 60.seconds

  # Schedules a build for an asset publish, unless a window is open already.
  #
  # ⚠️ This is not `claim_trigger_lock` and not `schedule_in`. The trigger lock makes a publish
  # inside its window go away with no message, which this caller must never do. `schedule_in` owns
  # the one scheduled slot of the Republish dialog, and an asset publish must not cancel a
  # republish that the owner asked for.
  # ⚠️ It cancels nothing, thus no publish is lost: the build runs after the publish that opened
  # the window and after each publish that joined it. A steady stream of publishes cannot push the
  # build back for all time.
  # @return [Boolean] true when this call scheduled the build.
  def self.coalesce_asset_build
    return false unless $redis.set(ASSET_WINDOW_KEY, "1", nx: true, ex: ASSET_WINDOW.to_i)

    perform_in(ASSET_WINDOW, CONTENTFUL_EVENT_TYPE)
    true
  end

  # Schedules a build, and cancels the build that is scheduled already.
  # @param delay [ActiveSupport::Duration] The time from now.
  # @param event_type [String] One of the three event types above.
  # @return [Boolean] true when this call cancelled a build that was scheduled.
  def self.schedule_in(delay, event_type)
    replaced = cancel_scheduled
    jid = perform_in(delay, event_type)
    begin
      # The key must outlive the job, thus the TTL adds a margin to the delay.
      $redis.set(SCHEDULED_JID_KEY, jid, ex: delay.to_i + TRIGGER_LOCK_TTL.to_i)
    rescue StandardError
      # ⚠️ A job with no jid in the key is one that cancel_scheduled can never find. Remove it,
      # then let the caller see the failure.
      Sidekiq::ScheduledSet.new.find_job(jid)&.delete
      raise
    end
    replaced
  end

  # Removes the scheduled build from the scheduled set of Sidekiq.
  #
  # ⚠️ The key can name a job that ran already, or one that a person deleted in `/sidekiq`.
  # `find_job` gives nil for both, thus this method then cancels nothing and says so.
  # @return [Boolean] true when a job left the scheduled set.
  def self.cancel_scheduled
    jid = $redis.getdel(SCHEDULED_JID_KEY)
    return false if jid.blank?

    !!Sidekiq::ScheduledSet.new.find_job(jid)&.delete
  end

  # The event type has a default, thus the Contentful caller stays a plain `perform_async`.
  def perform(event_type = CONTENTFUL_EVENT_TYPE)
    token = ENV["GITHUB_DISPATCH_TOKEN"]
    repo = ENV["GITHUB_REPOSITORY"]
    if token.blank? || repo.blank?
      Rails.logger.info("SiteBuildJob: GITHUB_DISPATCH_TOKEN/GITHUB_REPOSITORY unset; skipping web rebuild trigger")
      return
    end

    response = HTTParty.post(
      format(DISPATCH_URL, repo: repo),
      headers: {
        "Authorization" => "Bearer #{token}",
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28",
        "User-Agent" => "kona-api",
        "Content-Type" => "application/json"
      },
      body: { event_type: event_type }.to_json
    )

    unless response.success?
      message = "SiteBuildJob: GitHub repository_dispatch failed (HTTP #{response.code})"
      raise PermanentError, message if PERMANENT_STATUSES.include?(response.code.to_i)

      raise message
    end

    Rails.logger.info("SiteBuildJob: triggered web rebuild via repository_dispatch (#{event_type})")
  end
end
