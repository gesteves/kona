require "httparty"

# Builds the web site again and deploys it. It sends a GitHub `repository_dispatch`, and
# .github/workflows/web.yml waits for that event. There are three callers, and each one has its own
# event type: the Contentful webhook, POST /api/build, and the Republish dialog of the admin. They
# build in the same way, and they are different only to let the Slack notification of the deploy
# name the cause.
#
# ⚠️ The `repository_dispatch.types` of that workflow must contain all three event types. If not,
# GitHub accepts the event with a 204 and runs nothing, and it gives no message. The event type is
# always a constant from the caller, and never a request parameter.
#
# A publish of many entries sends more than one event, and the cancel-in-progress concurrency of the
# workflow makes them one build. This job does nothing when there is no configuration, and it raises
# on a non-2xx, thus Sidekiq does it again.
class SiteBuildJob < ApplicationJob
  DISPATCH_URL = "https://api.github.com/repos/%<repo>s/dispatches".freeze
  # All three of these are in `repository_dispatch.types` in .github/workflows/web.yml.
  CONTENTFUL_EVENT_TYPE = "contentful-publish".freeze
  MANUAL_EVENT_TYPE = "api-build".freeze
  ADMIN_EVENT_TYPE = "admin-republish".freeze

  # The window that stops a second "build now" from a person. The code never removes the lock: it
  # expires.
  TRIGGER_LOCK_KEY = "build:trigger_lock".freeze
  TRIGGER_LOCK_TTL = 60.seconds

  # Takes the "build now" lock. The two manual callers share it, thus a double click, or a click
  # after a curl, cannot start two Actions runs.
  #
  # ⚠️ The Contentful webhook must never call this. A publish inside the window would go away with
  # no message, and the site would stay old.
  # @return [Boolean] true when this caller took the lock, and false while it belongs to another
  #   one.
  def self.claim_trigger_lock
    !!$redis.set(TRIGGER_LOCK_KEY, "1", nx: true, ex: TRIGGER_LOCK_TTL.to_i)
  end

  # This has a default value and it is not necessary. Thus the Contentful caller stays a plain
  # `perform_async`, and a job that goes into the queue with no arguments before a deploy still runs
  # after that deploy.
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

    raise "SiteBuildJob: GitHub repository_dispatch failed (HTTP #{response.code})" unless response.success?

    Rails.logger.info("SiteBuildJob: triggered web rebuild via repository_dispatch (#{event_type})")
  end
end
