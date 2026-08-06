require "httparty"

# Rebuilds and redeploys the web site by firing a GitHub `repository_dispatch`, which
# .github/workflows/web.yml listens for. Two callers, one event type each — the Contentful
# webhook and POST /api/build. They build identically and differ only so the deploy's Slack
# notification can name the trigger.
#
# ⚠️ Both event types must be listed in that workflow's `repository_dispatch.types`, or GitHub
# accepts the dispatch with a 204 and silently runs nothing. The event type is always a
# caller-supplied constant, never a request parameter.
#
# A bulk publish fires several dispatches; the workflow's cancel-in-progress concurrency
# collapses them into one build. No-ops when unconfigured, and raises on a non-2xx so Sidekiq
# retries.
class SiteBuildJob < ApplicationJob
  DISPATCH_URL = "https://api.github.com/repos/%<repo>s/dispatches".freeze
  # Both match `repository_dispatch.types` in .github/workflows/web.yml.
  CONTENTFUL_EVENT_TYPE = "contentful-publish".freeze
  MANUAL_EVENT_TYPE = "api-build".freeze

  # Defaulted rather than required, so the Contentful caller stays a bare `perform_async` and a
  # job enqueued with no args before a deploy still runs after it.
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
