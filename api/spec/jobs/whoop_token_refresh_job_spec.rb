require "rails_helper"

RSpec.describe WhoopTokenRefreshJob do
  let(:whoop) { instance_double(Whoop, valid_credentials?: true, connected?: true, account_email: "athlete@example.com") }

  before { allow(Whoop).to receive(:new).and_return(whoop) }

  it "forces a token refresh" do
    expect(whoop).to receive(:refresh_tokens!).and_return("fresh-token")
    described_class.new.perform
  end

  # The Connected apps page names the connected account, and it reads that label from Redis only.
  # Thus this job is what fills it in for a connection that this app made before it stored one.
  it "stores the athlete's email when the label is missing" do
    allow(whoop).to receive(:refresh_tokens!).and_return("fresh-token")
    allow(whoop).to receive(:account_email).and_return(nil)

    expect(whoop).to receive(:store_account_email!)

    described_class.new.perform
  end

  it "does not fetch the label again once it is stored" do
    allow(whoop).to receive(:refresh_tokens!).and_return("fresh-token")

    expect(whoop).not_to receive(:store_account_email!)

    described_class.new.perform
  end

  it "does nothing when the credentials aren't configured" do
    allow(whoop).to receive(:valid_credentials?).and_return(false)
    expect(whoop).not_to receive(:refresh_tokens!)
    described_class.new.perform
  end

  it "does nothing when no account is connected" do
    allow(whoop).to receive(:connected?).and_return(false)
    expect(whoop).not_to receive(:refresh_tokens!)
    described_class.new.perform
  end

  # Whoop#refresh_access_token already wrote the failure to the log and sent a report. The next run
  # of this job is the next attempt. Thus the job must not raise, because it would then use a
  # 24-hour retry window against a token that Whoop removed.
  it "warns rather than raising when the refresh fails" do
    allow(whoop).to receive(:refresh_tokens!).and_return(nil)
    expect(Rails.logger).to receive(:warn).with(/re-authorize/)
    expect { described_class.new.perform }.not_to raise_error
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
