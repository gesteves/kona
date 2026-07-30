require "rails_helper"

RSpec.describe AssetSyncJob do
  let(:service) { instance_double(AssetMirror) }

  before { allow(AssetMirror).to receive(:new).and_return(service) }

  it "mirrors the asset by id" do
    expect(service).to receive(:sync).with("asset1")
    described_class.new.perform("asset1")
  end

  # Unlike most jobs here, a failure must not be swallowed: an unmirrored asset shows up later
  # as a broken image on a live page, so it has to reach Sidekiq's retry.
  it "lets a mirror failure raise so Sidekiq retries" do
    allow(service).to receive(:sync).and_raise(ApplicationService::HttpError.new(503, "", "https://example.com"))
    expect { described_class.new.perform("asset1") }.to raise_error(ApplicationService::HttpError)
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
