require "rails_helper"

RSpec.describe StravaFtpJob do
  let(:strava) { instance_double(Strava, connected?: true) }

  before { allow(Strava).to receive(:new).and_return(strava) }

  it "writes the FTP to Strava" do
    expect(strava).to receive(:update_athlete_ftp!).with(265).and_return(265)
    described_class.new.perform(265)
  end

  it "fails permanently when Strava is not connected" do
    allow(strava).to receive(:connected?).and_return(false)
    expect { described_class.new.perform(265) }.to raise_error(ApplicationJob::PermanentError)
  end

  it "fails permanently when Strava ignores the FTP" do
    allow(strava).to receive(:update_athlete_ftp!).and_return(250)
    expect { described_class.new.perform(265) }.to raise_error(ApplicationJob::PermanentError, /ignored/)
  end

  it "fails permanently when Strava refuses the scope" do
    allow(strava).to receive(:update_athlete_ftp!).and_raise(ApplicationService::HttpError.new(403, "", "url"))
    expect { described_class.new.perform(265) }.to raise_error(ApplicationJob::PermanentError, /profile:write/)
  end

  it "raises other failures, thus Sidekiq retries" do
    allow(strava).to receive(:update_athlete_ftp!).and_raise(ApplicationService::HttpError.new(500, "", "url"))
    expect { described_class.new.perform(265) }.to raise_error(ApplicationService::HttpError)
  end
end
