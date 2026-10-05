require "rails_helper"

RSpec.describe StravaWeightJob do
  let(:strava) { instance_double(Strava, connected?: true) }

  before { allow(Strava).to receive(:new).and_return(strava) }

  it "writes the weight to Strava" do
    expect(strava).to receive(:update_athlete_weight!).with(72.4)
    described_class.new.perform(72.4)
  end

  it "fails permanently when Strava is not connected" do
    allow(strava).to receive(:connected?).and_return(false)
    expect { described_class.new.perform(72.4) }.to raise_error(ApplicationJob::PermanentError)
  end

  it "fails permanently when Strava refuses the scope" do
    allow(strava).to receive(:update_athlete_weight!).and_raise(ApplicationService::HttpError.new(401, "", "url"))
    expect { described_class.new.perform(72.4) }.to raise_error(ApplicationJob::PermanentError, /profile:write/)
  end

  it "raises other failures, thus Sidekiq retries" do
    allow(strava).to receive(:update_athlete_weight!).and_raise(ApplicationService::HttpError.new(500, "", "url"))
    expect { described_class.new.perform(72.4) }.to raise_error(ApplicationService::HttpError)
  end
end
