require "rails_helper"

RSpec.describe IntervalsWeightJob do
  let(:intervals) { instance_double(Intervals) }

  before { allow(Intervals).to receive(:new).and_return(intervals) }

  it "writes the weight to the wellness record of the day" do
    expect(intervals).to receive(:update_wellness!).with("2026-10-05", weight: 72.4)
    described_class.new.perform(72.4, "2026-10-05")
  end
end
