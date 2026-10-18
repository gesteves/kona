require "rails_helper"

RSpec.describe SubmissionTime do
  include ActiveSupport::Testing::TimeHelpers

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TIME_ZONE").and_return("America/Los_Angeles")
  end

  it "gives the local time to the second, with the UTC value" do
    expect(described_class.format("2026-08-01T12:00:12Z")).to eq("Saturday, August 1, 2026, 5:00:12 AM PDT (2026-08-01T12:00:12Z)")
  end

  it "gives the current time for a blank value" do
    travel_to(Time.utc(2026, 12, 1, 18, 30, 5)) do
      expect(described_class.format(nil)).to eq("Tuesday, December 1, 2026, 10:30:05 AM PST (2026-12-01T18:30:05Z)")
    end
  end

  # A raise in ContactMailJob would stop the delivery.
  it "gives a value that it cannot parse with no change" do
    expect(described_class.format("yesterday")).to eq("yesterday")
  end
end
