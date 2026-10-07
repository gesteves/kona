require "rails_helper"

RSpec.describe IntervalsFtpJob do
  let(:intervals) { instance_double(Intervals) }

  before { allow(Intervals).to receive(:new).and_return(intervals) }

  it "writes the FTP and the indoor FTP to the Ride sport settings" do
    expect(intervals).to receive(:update_sport_settings!).with("Ride", ftp: 265, indoor_ftp: 265)
    described_class.new.perform(265)
  end
end
