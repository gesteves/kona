require "rails_helper"

RSpec.describe StravaNameJob do
  let(:strava) { instance_double(Strava, connected?: true, update_activity!: nil) }

  before { allow(Strava).to receive(:new).and_return(strava) }

  it "corrects a Rouvy name" do
    allow(strava).to receive(:activity).with("123").and_return({ name: "ROUVY - Klahane Ridge - 2026-08-12", description: nil })

    described_class.new.perform("123")

    expect(strava).to have_received(:update_activity!).with("123", name: "Rouvy - Klahane Ridge")
  end

  it "writes nothing for a name that needs no correction" do
    allow(strava).to receive(:activity).and_return({ name: "Morning Ride", description: nil })

    described_class.new.perform("123")

    expect(strava).not_to have_received(:update_activity!)
  end

  it "writes nothing for a blank name" do
    allow(strava).to receive(:activity).and_return({ name: nil, description: nil })

    described_class.new.perform("123")

    expect(strava).not_to have_received(:update_activity!)
  end

  it "does nothing when Strava is not connected" do
    allow(strava).to receive(:connected?).and_return(false)
    allow(strava).to receive(:activity)

    described_class.new.perform("123")

    expect(strava).not_to have_received(:activity)
    expect(strava).not_to have_received(:update_activity!)
  end

  it "raises a Strava failure, thus Sidekiq retries" do
    allow(strava).to receive(:activity).and_raise(ApplicationService::HttpError.new(500, "", "url"))

    expect { described_class.new.perform("123") }.to raise_error(ApplicationService::HttpError)
  end
end
