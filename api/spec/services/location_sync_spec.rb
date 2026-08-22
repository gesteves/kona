require "rails_helper"

RSpec.describe LocationSync do
  subject(:sync) { described_class.new(intervals: intervals) }

  let(:intervals) do
    instance_double(
      Intervals,
      athlete_profile: profile,
      weather_config: forecasts,
      update_athlete_profile: nil,
      update_weather_config: nil,
      cache_athlete_timezone: nil
    )
  end

  let(:context) do
    instance_double(
      LocationContext,
      city: "Denver",
      state: "Colorado",
      country: "United States",
      timezone: "America/Denver",
      label: "Denver, Colorado",
      location: "Denver, Colorado, United States",
      lat: 39.7,
      lon: -104.9
    )
  end

  # Intervals.icu already has the same values as the resolved context.
  let(:profile) { { city: "Denver", state: "Colorado", country: "United States", timezone: "America/Denver" } }
  let(:forecasts) do
    [ { id: 7, provider: "OPEN_WEATHER", location: "Denver, Colorado, United States", label: "Denver, Colorado", lat: 39.7, lon: -104.9, enabled: true } ]
  end

  before { allow(LocationContext).to receive(:new).with(39.7, -104.9).and_return(context) }

  it "writes nothing (and primes nothing) when Intervals.icu already matches" do
    sync.call(39.7, -104.9)

    expect(intervals).not_to have_received(:update_athlete_profile)
    expect(intervals).not_to have_received(:update_weather_config)
    expect(intervals).not_to have_received(:cache_athlete_timezone)
  end

  context "when a profile field differs" do
    before { allow(intervals).to receive(:athlete_profile).and_return(profile.merge(city: "Boulder")) }

    it "updates the profile with only the resolved fields and primes the timezone cache" do
      sync.call(39.7, -104.9)

      expect(intervals).to have_received(:update_athlete_profile)
        .with(city: "Denver", state: "Colorado", country: "United States", timezone: "America/Denver")
      expect(intervals).to have_received(:cache_athlete_timezone).with("America/Denver")
    end
  end

  context "when the weather config differs" do
    before { allow(intervals).to receive(:weather_config).and_return([ forecasts.first.merge(label: "Old Place") ]) }

    it "replaces it with a single current-location forecast (id 0)" do
      sync.call(39.7, -104.9)

      expect(intervals).to have_received(:update_weather_config).with(
        [ hash_including(id: 0, provider: "OPEN_WEATHER", location: "Denver, Colorado, United States",
                        label: "Denver, Colorado", lat: 39.7, lon: -104.9, enabled: true) ]
      )
    end

    it "does not prime the timezone cache when only the weather config changed" do
      sync.call(39.7, -104.9)

      expect(intervals).not_to have_received(:cache_athlete_timezone)
    end
  end

  it "treats an id-only difference in the weather config as equal (no write)" do
    allow(intervals).to receive(:weather_config).and_return([ forecasts.first.merge(id: 99_999) ])

    sync.call(39.7, -104.9)

    expect(intervals).not_to have_received(:update_weather_config)
  end

  context "when the timezone lookup returned nil" do
    before do
      allow(context).to receive(:timezone).and_return(nil)
      allow(intervals).to receive(:athlete_profile).and_return(profile.merge(city: "Boulder"))
    end

    it "omits the timezone from the write and does not prime the cache" do
      sync.call(39.7, -104.9)

      expect(intervals).to have_received(:update_athlete_profile)
        .with(city: "Denver", state: "Colorado", country: "United States")
      expect(intervals).not_to have_received(:cache_athlete_timezone)
    end
  end

  it "skips the profile write entirely when nothing resolved" do
    allow(context).to receive_messages(city: nil, state: nil, country: nil, timezone: nil)

    sync.call(39.7, -104.9)

    expect(intervals).not_to have_received(:athlete_profile)
    expect(intervals).not_to have_received(:update_athlete_profile)
  end
end
