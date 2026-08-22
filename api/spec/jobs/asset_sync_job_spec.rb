require "rails_helper"

RSpec.describe AssetSyncJob do
  let(:service) { instance_double(AssetMirror) }

  before { allow(AssetMirror).to receive(:new).and_return(service) }

  it "mirrors the asset by id" do
    expect(service).to receive(:sync).with("asset1")
    described_class.new.perform("asset1")
  end

  # Most of the jobs here are different: the code must not catch a failure. An asset that it does not
  # copy becomes a broken image on a live page later, thus the failure must reach the retry of
  # Sidekiq.
  it "lets a mirror failure raise so Sidekiq retries" do
    allow(service).to receive(:sync).and_raise(ApplicationService::HttpError.new(503, "", "https://example.com"))
    expect { described_class.new.perform("asset1") }.to raise_error(ApplicationService::HttpError)
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
