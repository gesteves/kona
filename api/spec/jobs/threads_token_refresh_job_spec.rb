require "rails_helper"

RSpec.describe ThreadsTokenRefreshJob do
  # ⚠️ A Threads token dies 60 days after the app got it, and an expired one cannot be renewed.
  # Thus this job is what keeps the connection, and a failure must never stop it running tomorrow.
  it "renews the token" do
    expect_any_instance_of(Threads).to receive(:refresh!).and_return(:refreshed)

    expect { described_class.new.perform }.not_to raise_error
  end

  it "does not raise when the token is still too new to refresh" do
    allow_any_instance_of(Threads).to receive(:refresh!).and_return(:too_soon)

    expect { described_class.new.perform }.not_to raise_error
  end

  # ⚠️ A raise would use the 24-hour retry of the parent class against an endpoint that refuses a
  # token which is less than 24 hours old. The next daily run is the next attempt.
  it "does not raise when the refresh fails" do
    allow_any_instance_of(Threads).to receive(:refresh!).and_return(:failed)

    expect { described_class.new.perform }.not_to raise_error
  end

  it "does nothing when no account is connected" do
    allow_any_instance_of(Threads).to receive(:refresh!).and_return(:skipped)

    expect { described_class.new.perform }.not_to raise_error
  end
end
