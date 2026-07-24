require "httparty"

# Triggers a rebuild + redeploy of the web site (the kona-web Cloudflare Worker's static assets)
# by firing a GitHub `repository_dispatch` event, which the `.github/workflows/web.yml` "Web"
# workflow listens for (`types: [contentful-publish]`). Enqueued by
# Webhooks::ContentfulController on every publish/unpublish/delete delivery — the web build reads
# the latest published content from Contentful at build time, so a fresh build reflects the change.
#
# Runs off the webhook request path (Contentful expects a fast 2xx). A bulk publish enqueues one
# job per entry, so several dispatches fire; the web workflow's cancel-in-progress concurrency
# collapses them into a single build.
#
# No-op when unconfigured (missing token or repo), so development and any non-production
# environment stay inert. Raises on a non-2xx GitHub response so Sidekiq retries.
class SiteBuildJob < ApplicationJob
  DISPATCH_URL = "https://api.github.com/repos/%<repo>s/dispatches".freeze
  # Matches `repository_dispatch.types` in .github/workflows/web.yml.
  EVENT_TYPE = "contentful-publish".freeze

  def perform
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
      body: { event_type: EVENT_TYPE }.to_json
    )

    raise "SiteBuildJob: GitHub repository_dispatch failed (HTTP #{response.code})" unless response.success?

    Rails.logger.info("SiteBuildJob: triggered web rebuild via repository_dispatch (#{EVENT_TYPE})")
  end
end
