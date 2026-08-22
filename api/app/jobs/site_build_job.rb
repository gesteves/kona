require "httparty"

# Builds the web site again and deploys it. It sends a GitHub `repository_dispatch`, and
# .github/workflows/web.yml waits for that event. There are two callers, and each one has its own
# event type: the Contentful webhook and POST /api/build. They build in the same way, and they are
# different only to let the Slack notification of the deploy name the cause.
#
# ⚠️ The `repository_dispatch.types` of that workflow must contain both event types. If not, GitHub
# accepts the event with a 204 and runs nothing, and it gives no message. The event type is always a
# constant from the caller, and never a request parameter.
#
# A publish of many entries sends more than one event, and the cancel-in-progress concurrency of the
# workflow makes them one build. This job does nothing when there is no configuration, and it raises
# on a non-2xx, thus Sidekiq does it again.
class SiteBuildJob < ApplicationJob
  DISPATCH_URL = "https://api.github.com/repos/%<repo>s/dispatches".freeze
  # Both of these are in `repository_dispatch.types` in .github/workflows/web.yml.
  CONTENTFUL_EVENT_TYPE = "contentful-publish".freeze
  MANUAL_EVENT_TYPE = "api-build".freeze

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
