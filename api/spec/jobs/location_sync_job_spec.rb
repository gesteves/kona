require "rails_helper"

RSpec.describe LocationSyncJob do
  let(:location_sync) { instance_double(LocationSync) }

  before { allow(LocationSync).to receive(:new).and_return(location_sync) }

  it "syncs the coordinates to Intervals.icu" do
    $redis.set(Location::LOCATION_CACHE_KEY, "43.48,-110.76")
    expect(location_sync).to receive(:call).with(43.48, -110.76)
    described_class.new.perform(43.48, -110.76)
  end

  # Two saves close together, or a late retry, must not put an older location on Intervals.icu.
  it "sends nothing when the coordinates are no longer the stored location" do
    $redis.set(Location::LOCATION_CACHE_KEY, "37.77,-122.42")
    expect(location_sync).not_to receive(:call)
    described_class.new.perform(43.48, -110.76)
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
