require "rails_helper"

RSpec.describe ActivityDescriptionJob do
  let(:generator) { instance_double(ActivityDescription::Generator) }

  before { allow(ActivityDescription::Generator).to receive(:new).and_return(generator) }

  it "generates the description for the activity, passing the optional Whoop strain" do
    expect(generator).to receive(:generate!).with("i1", whoop_strain: 12.4, lock_token: nil)
    described_class.new.perform("i1", 12.4)
  end

  it "generates without a strain when none is supplied (e.g. a non-Whoop trigger)" do
    expect(generator).to receive(:generate!).with("i1", whoop_strain: nil, lock_token: nil)
    described_class.new.perform("i1")
  end

  # The jid is the token of the lock, thus a retry can enter the lock that its own attempt left.
  it "gives its jid to the generator as the lock token" do
    job = described_class.new
    job.jid = "job-1"
    expect(generator).to receive(:generate!).with("i1", whoop_strain: nil, lock_token: "job-1")
    job.perform("i1")
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
