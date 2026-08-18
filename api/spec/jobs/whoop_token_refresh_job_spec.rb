require "rails_helper"

RSpec.describe WhoopTokenRefreshJob do
  let(:whoop) { instance_double(Whoop, valid_credentials?: true, connected?: true) }

  before { allow(Whoop).to receive(:new).and_return(whoop) }

  it "forces a token refresh" do
    expect(whoop).to receive(:refresh_tokens!).and_return("fresh-token")
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

  # Whoop#refresh_access_token has already logged and reported the failure; the next tick is the
  # retry, so the job must not raise into a 24-hour retry window against a revoked token.
  it "warns rather than raising when the refresh fails" do
    allow(whoop).to receive(:refresh_tokens!).and_return(nil)
    expect(Rails.logger).to receive(:warn).with(/re-authorize/)
    expect { described_class.new.perform }.not_to raise_error
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
