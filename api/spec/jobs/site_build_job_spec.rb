require "rails_helper"

RSpec.describe SiteBuildJob do
  let(:success) { instance_double(HTTParty::Response, success?: true, code: 204) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GITHUB_DISPATCH_TOKEN").and_return("ghp_test")
    allow(ENV).to receive(:[]).with("GITHUB_REPOSITORY").and_return("owner/kona")
  end

  it "POSTs a repository_dispatch event to the configured repo with the auth + api headers" do
    expect(HTTParty).to receive(:post).with(
      "https://api.github.com/repos/owner/kona/dispatches",
      hash_including(
        headers: hash_including(
          "Authorization" => "Bearer ghp_test",
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => "2022-11-28",
          "User-Agent" => "kona-api"
        ),
        body: { event_type: "contentful-publish" }.to_json
      )
    ).and_return(success)

    described_class.new.perform
  end

  it "dispatches the event type it's given (the /api/build caller's)" do
    expect(HTTParty).to receive(:post).with(
      "https://api.github.com/repos/owner/kona/dispatches",
      hash_including(body: { event_type: "api-build" }.to_json)
    ).and_return(success)

    described_class.new.perform("api-build")
  end

  it "raises on a non-2xx response so Sidekiq retries" do
    allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, success?: false, code: 403))
    expect { described_class.new.perform }.to raise_error(/repository_dispatch failed \(HTTP 403\)/)
  end

  it "is a no-op (no HTTP call) when GITHUB_DISPATCH_TOKEN is unset" do
    allow(ENV).to receive(:[]).with("GITHUB_DISPATCH_TOKEN").and_return(nil)
    expect(HTTParty).not_to receive(:post)
    described_class.new.perform
  end

  it "is a no-op (no HTTP call) when GITHUB_REPOSITORY is unset" do
    allow(ENV).to receive(:[]).with("GITHUB_REPOSITORY").and_return(nil)
    expect(HTTParty).not_to receive(:post)
    described_class.new.perform
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
