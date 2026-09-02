require "rails_helper"

RSpec.describe ApplicationJob do
  it "retries each job for a day" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end

  # ⚠️ A failure that no retry can correct must not use that day: the job goes to the Dead set.
  it "kills a job that raises a PermanentError, and keeps the retry for each other error" do
    block = described_class.sidekiq_retry_in_block
    expect(block.call(1, described_class::PermanentError.new("not connected"))).to eq(:kill)
    expect(block.call(1, RuntimeError.new("boom"))).to be_nil
  end
end
