require "rails_helper"

RSpec.describe ActivityDescriptionJob do
  let(:generator) { instance_double(ActivityDescription::Generator) }

  before { allow(ActivityDescription::Generator).to receive(:new).and_return(generator) }

  it "generates the description for the activity" do
    expect(generator).to receive(:generate!).with("i1", lock_token: nil)
    described_class.new.perform("i1")
  end

  # The jid is the token of the lock, thus a retry can enter the lock that its own attempt left.
  it "gives its jid to the generator as the lock token" do
    job = described_class.new
    job.jid = "job-1"
    expect(generator).to receive(:generate!).with("i1", lock_token: "job-1")
    job.perform("i1")
  end

  # ⚠️ The second of two close webhooks can be the run with the Whoop strain, thus it must not go away.
  it "runs again later when another run holds the lock" do
    allow(generator).to receive(:generate!).and_return(:busy)

    described_class.new.perform("i1")

    expect(described_class).to have_enqueued_sidekiq_job("i1").in(described_class::BUSY_DELAY)
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
