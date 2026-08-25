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

  it "dispatches the event type it's given (the admin Republish caller's)" do
    expect(HTTParty).to receive(:post).with(
      "https://api.github.com/repos/owner/kona/dispatches",
      hash_including(body: { event_type: "admin-republish" }.to_json)
    ).and_return(success)

    described_class.new.perform(described_class::ADMIN_EVENT_TYPE)
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

  describe ".claim_trigger_lock" do
    it "takes the shared build-now lock with a 60-second expiry" do
      expect($redis).to receive(:set).with("build:trigger_lock", "1", nx: true, ex: 60).and_return(true)

      expect(described_class.claim_trigger_lock).to be(true)
    end

    it "is false while another caller holds the lock" do
      allow($redis).to receive(:set).and_return(false)

      expect(described_class.claim_trigger_lock).to be(false)
    end
  end

  describe "the scheduled republish" do
    let(:scheduled_set) { instance_double(Sidekiq::ScheduledSet) }
    let(:scheduled_job) { instance_double(Sidekiq::SortedEntry) }

    before do
      allow(Sidekiq::ScheduledSet).to receive(:new).and_return(scheduled_set)
      allow($redis).to receive(:getdel).with("build:scheduled_jid").and_return(nil)
      allow($redis).to receive(:set)
    end

    it "keeps the jid, with a TTL that outlives the job" do
      allow(described_class).to receive(:perform_in).and_return("abc123")
      expect($redis).to receive(:set).with("build:scheduled_jid", "abc123", ex: 10.minutes.to_i + 60)

      described_class.schedule_in(10.minutes, described_class::ADMIN_EVENT_TYPE)
    end

    it "cancels the build that is scheduled before it schedules the next one" do
      allow($redis).to receive(:getdel).with("build:scheduled_jid").and_return("old-jid")
      allow(scheduled_set).to receive(:find_job).with("old-jid").and_return(scheduled_job)
      expect(scheduled_job).to receive(:delete).and_return(true)

      expect(described_class.schedule_in(5.minutes, described_class::ADMIN_EVENT_TYPE)).to be(true)
      expect(described_class).to have_enqueued_sidekiq_job("admin-republish").at(5.minutes.from_now)
    end

    it "says that it cancelled nothing when no build is scheduled" do
      expect(described_class.cancel_scheduled).to be(false)
    end

    # ⚠️ The jid can name a job that ran already, or one that a person deleted in /sidekiq.
    it "says that it cancelled nothing when the jid is no longer in the scheduled set" do
      allow($redis).to receive(:getdel).with("build:scheduled_jid").and_return("gone")
      allow(scheduled_set).to receive(:find_job).with("gone").and_return(nil)

      expect(described_class.cancel_scheduled).to be(false)
    end
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
