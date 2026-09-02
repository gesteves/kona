require "rails_helper"

RSpec.describe Intervals do
  subject(:service) { described_class.new }

  before do
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  describe "#stats" do
    it "sums distances by discipline and counts only tri activities" do
      activities = [
        { "type" => "Swim",         "distance" => 1000 },
        { "type" => "OpenWaterSwim", "distance" => 1500 },
        { "type" => "Ride",         "distance" => 20000 },
        { "type" => "VirtualRide",  "distance" => 10000 },
        { "type" => "Run",          "distance" => 5000 },
        { "type" => "Walk",         "distance" => 3000 } # ignored
      ]
      allow(service).to receive(:get_json).and_return(activities)

      expect(service.stats).to eq(
        swim_distance: 2500, bike_distance: 30000, run_distance: 5000, total_activities: 5
      )
    end

    it "treats a missing distance as zero" do
      allow(service).to receive(:get_json).and_return([ { "type" => "Run" } ])
      expect(service.stats[:run_distance]).to eq(0)
    end

    it "returns nil when activities can't be fetched, and keeps that failure for a minute" do
      allow(service).to receive(:get_json).and_return(nil)
      expect(service.stats).to be_nil
      expect($redis).to have_received(:setex).with("intervals.icu:stats:#{service.instance_variable_get(:@athlete_id)}", 60, ApplicationService::EMPTY_SENTINEL)
    end
  end

  describe "#athlete_timezone" do
    it "reads the timezone from the nested profile endpoint" do
      allow(service).to receive(:get_json!).and_return({ athlete: { id: "i1", timezone: "America/Denver" } })
      expect(service.athlete_timezone).to eq("America/Denver")
    end

    it "falls back to UTC on any error" do
      allow(service).to receive(:get_json!).and_raise(ApplicationService::HttpError.new(500, "boom", "url"))
      expect(service.athlete_timezone).to eq("UTC")
    end
  end

  describe "#temperature_unit" do
    it "honors the explicit fahrenheit flag" do
      allow(service).to receive(:get_json!).and_return({ fahrenheit: true, measurement_preference: "meters" })
      expect(service.temperature_unit).to eq(:fahrenheit)
    end

    it "derives fahrenheit from an imperial measurement preference" do
      allow(service).to receive(:get_json!).and_return({ measurement_preference: "feet" })
      expect(service.temperature_unit).to eq(:fahrenheit)
    end

    it "defaults metric athletes to celsius, and to celsius on error" do
      allow(service).to receive(:get_json!).and_return({ measurement_preference: "meters" })
      expect(service.temperature_unit).to eq(:celsius)

      allow(service).to receive(:get_json!).and_raise("boom")
      expect(service.temperature_unit).to eq(:celsius)
    end
  end

  describe "#activity_weather_summary" do
    it "strips the Intervals.icu attribution prefix" do
      allow(service).to receive(:get_json!).and_return({ description: "-- Intervals icu --\n18°C, sunny, light wind" })
      expect(service.activity_weather_summary("a1")).to eq("18°C, sunny, light wind")
    end

    it "returns nil when weather isn't available" do
      allow(service).to receive(:get_json!).and_raise(ApplicationService::HttpError.new(404, "", "url"))
      expect(service.activity_weather_summary("a1")).to be_nil
    end
  end

  describe "#activity_streams" do
    it "requests repeated bare types params (not HTTParty's array form)" do
      allow(service).to receive(:get_json!).and_return([])

      service.activity_streams("a1", types: %w[heat_strain_index time])

      expect(service).to have_received(:get_json!)
        .with(%r{/activity/a1/streams\?types=heat_strain_index&types=time\z}, anything)
    end

    it "returns nil when streams aren't available" do
      allow(service).to receive(:get_json!).and_raise("boom")
      expect(service.activity_streams("a1", types: %w[temp time])).to be_nil
    end
  end

  describe "wellness and activity writes" do
    it "PUTs partial wellness updates with basic auth and raises HttpError on failure" do
      response = instance_double(HTTParty::Response, success?: false, code: 422, body: "no such field", request: nil)
      allow(HTTParty).to receive(:put).and_return(response)

      expect { service.update_wellness!("2026-07-09", WhoopStrain: 14.2) }
        .to raise_error(ApplicationService::HttpError) { |e| expect(e.status).to eq(422) }

      expect(HTTParty).to have_received(:put).with(
        %r{/athlete/.*/wellness/2026-07-09\z},
        hash_including(body: { WhoopStrain: 14.2 }.to_json, basic_auth: hash_including(username: "API_KEY"))
      )
    end

    it "PUTs partial activity updates" do
      response = instance_double(HTTParty::Response, success?: true, code: 200, body: "{}", request: nil)
      allow(HTTParty).to receive(:put).and_return(response)

      service.update_activity!("a1", description: "new")

      expect(HTTParty).to have_received(:put).with(
        %r{/activity/a1\z},
        hash_including(body: { description: "new" }.to_json)
      )
    end
  end

  describe "location sync reads and writes" do
    let(:ok) { instance_double(HTTParty::Response, success?: true, code: 200, body: "{}", request: nil) }

    it "reads the athlete profile fresh (uncached) with basic auth" do
      expect(service).to receive(:get_json!)
        .with(a_string_matching(%r{/athlete/}), hash_including(basic_auth: hash_including(username: "API_KEY")))
        .and_return({ city: "Denver", timezone: "America/Denver" })

      expect(service.athlete_profile).to include(city: "Denver", timezone: "America/Denver")
    end

    it "PUTs only the present profile fields as JSON" do
      allow(HTTParty).to receive(:put).and_return(ok)

      service.update_athlete_profile(city: "Denver", timezone: "America/Denver")

      expect(HTTParty).to have_received(:put).with(
        %r{/athlete/[^/]*\z},
        hash_including(body: { city: "Denver", timezone: "America/Denver" }.to_json, basic_auth: hash_including(username: "API_KEY"))
      )
    end

    it "returns the weather-config forecasts array (empty when none configured)" do
      allow(service).to receive(:get_json!).and_return({ forecasts: [ { id: 1 } ] })
      expect(service.weather_config).to eq([ { id: 1 } ])

      allow(service).to receive(:get_json!).and_return({})
      expect(service.weather_config).to eq([])
    end

    it "PUTs the weather config wrapped under :forecasts" do
      allow(HTTParty).to receive(:put).and_return(ok)
      forecasts = [ { id: 0, provider: "OPEN_WEATHER", enabled: true } ]

      service.update_weather_config(forecasts)

      expect(HTTParty).to have_received(:put).with(
        %r{/athlete/[^/]*/weather-config\z},
        hash_including(body: { forecasts: forecasts }.to_json)
      )
    end

    it "primes the timezone cache with the same JSON encoding and 1-hour TTL athlete_timezone reads" do
      service.cache_athlete_timezone("America/Denver")

      expect($redis).to have_received(:setex)
        .with(a_string_matching(/\Aintervals\.icu:timezone:/), 3600, "America/Denver".to_json)
    end
  end
end
