require "rails_helper"

RSpec.describe LocationPresenter do
  def presenter(stored: nil, override: nil, map_token: "pk.token", place: "Jackson Hole, Wyoming",
                time_zone: "America/Denver")
    described_class.new(
      stored: stored,
      override: override,
      place: place,
      time_zone: time_zone,
      map_token: map_token,
      map_style: "mapbox://styles/mapbox/streets-v12",
      location_zoom: 11,
      world_zoom: 1,
      save_path: "/location"
    )
  end

  describe "the coordinates in effect" do
    it "uses the stored pair" do
      subject = presenter(stored: [ 43.48, -110.76 ])

      expect(subject.latitude).to eq(43.48)
      expect(subject.longitude).to eq(-110.76)
      expect(subject.summary).to eq("43.48, -110.76")
      expect(subject).to be_set
    end

    # Location reads the env var first, so the page has to show what actually wins.
    it "prefers the override, and says it's overridden" do
      subject = presenter(stored: [ 43.48, -110.76 ], override: [ 37.77, -122.42 ])

      expect(subject.latitude).to eq(37.77)
      expect(subject).to be_overridden
      expect(subject.override_summary).to eq("37.77, -122.42")
    end

    it "is unset with neither" do
      subject = presenter

      expect(subject).not_to be_set
      expect(subject).not_to be_overridden
      expect(subject.summary).to be_nil
    end
  end

  describe "what it says about the place" do
    it "leads with the name the weather widget would print" do
      subject = presenter(stored: [ 43.48, -110.76 ])

      expect(subject.heading).to eq("Jackson Hole, Wyoming")
      expect(subject.details).to eq("43.48, -110.76 · America/Denver")
    end

    # A geocode that resolves to nothing is what the widget would render as a blank; the
    # coordinates are more use than a placeholder.
    it "falls back to the coordinates when nothing geocoded" do
      subject = presenter(stored: [ 43.48, -110.76 ], place: nil, time_zone: nil)

      expect(subject.heading).to eq("43.48, -110.76")
      expect(subject.details).to eq("43.48, -110.76")
    end

    it "asks for a first pin when there's no location at all" do
      subject = presenter(place: nil, time_zone: nil)

      expect(subject.heading).to eq("Nowhere yet")
      expect(subject.details).to include("Drop a pin")
    end
  end

  describe "the map" do
    # ⚠️ Mapbox takes longitude first; passing a latitude-first pair puts the pin in the sea.
    it "centers longitude-first on the location" do
      expect(presenter(stored: [ 43.48, -110.76 ]).center).to eq([ -110.76, 43.48 ])
      expect(presenter(stored: [ 43.48, -110.76 ]).zoom).to eq(11)
    end

    it "falls back to the whole world" do
      expect(presenter.center).to eq(described_class::WORLD_CENTER)
      expect(presenter.zoom).to eq(1)
    end

    it "is unconfigured without a token" do
      expect(presenter(map_token: nil)).not_to be_configured
      expect(presenter).to be_configured
    end
  end
end
