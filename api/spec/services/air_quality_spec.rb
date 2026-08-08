require "rails_helper"

RSpec.describe AirQuality do
  subject(:service) { described_class.new(40.0, -105.0, "US") }

  let(:purple_air) { instance_double(PurpleAir) }
  let(:google) { instance_double(GoogleAirQuality) }

  before do
    allow(PurpleAir).to receive(:new).and_return(purple_air)
    allow(GoogleAirQuality).to receive(:new).and_return(google)
    allow(ErrorReporter).to receive(:report_upstream)
  end

  it "prefers PurpleAir and never asks Google when it answers" do
    allow(purple_air).to receive(:aqi).and_return({ aqi: 42, category: "Good" })

    expect(GoogleAirQuality).not_to receive(:new)
    expect(service.data.aqi).to eq(42)
    expect(service.data.category).to eq("Good")
  end

  it "falls back to Google when PurpleAir has no reading" do
    allow(purple_air).to receive(:aqi).and_return(nil)
    allow(google).to receive(:aqi).and_return({ aqi: 55 })

    expect(service.data.aqi).to eq(55)
  end

  # ⚠️ The regression this class exists to prevent: the providers are isolated separately, because
  # chaining them with `||=` alone let a PurpleAir *raise* propagate straight past the fallback —
  # so the fallback never ran in the one case it was written for.
  it "falls back to Google when PurpleAir raises" do
    allow(purple_air).to receive(:aqi).and_raise(StandardError, "purple air is down")
    allow(google).to receive(:aqi).and_return({ aqi: 55 })

    expect(service.data.aqi).to eq(55)
    expect(ErrorReporter).to have_received(:report_upstream).with(instance_of(StandardError), hash_including(service: "PurpleAir"))
  end

  it "returns nil when both providers fail" do
    allow(purple_air).to receive(:aqi).and_raise(StandardError, "down")
    allow(google).to receive(:aqi).and_raise(StandardError, "also down")

    expect(service.data).to be_nil
  end

  it "returns nil when neither provider has a reading" do
    allow(purple_air).to receive(:aqi).and_return(nil)
    allow(google).to receive(:aqi).and_return(nil)

    expect(service.data).to be_nil
  end
end
