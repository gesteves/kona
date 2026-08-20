require "rails_helper"

RSpec.describe LocationPresenter do
  include ActiveSupport::Testing::TimeHelpers

  # The zone the presenter reckons "upcoming" in, and the one the fixtures below date themselves
  # in — one source of truth, since a race's calendar day depends on both agreeing.
  def time_zone = "America/Denver"

  def presenter(stored: nil, override: nil, map_token: "pk.token", place: "Jackson Hole, Wyoming",
                events: [])
    described_class.new(
      stored: stored,
      override: override,
      place: place,
      events: events,
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

    # Display only — what's stored, and what #latitude/#longitude hand the map, is the full value.
    it "rounds the displayed pair to three decimals" do
      subject = presenter(stored: [ 43.478123, -110.762987 ])

      expect(subject.summary).to eq("43.478, -110.763")
      expect(subject.latitude).to eq(43.478123)
      expect(subject.center).to eq([ -110.762987, 43.478123 ])
    end

    # ⚠️ The one place that isn't rounded: it echoes what's in the environment, so it has to match
    # what was typed there.
    it "leaves the override callout's coordinates exact" do
      subject = presenter(override: [ 37.774929, -122.419418 ])

      expect(subject.override_summary).to eq("37.774929, -122.419418")
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
      expect(subject.details).to eq("43.48, -110.76")
    end

    # A geocode that resolves to nothing is what the widget would render as a blank; the
    # coordinates are more use than a placeholder.
    it "falls back to the coordinates when nothing geocoded" do
      subject = presenter(stored: [ 43.48, -110.76 ], place: nil)

      expect(subject.heading).to eq("43.48, -110.76")
      expect(subject.details).to eq("43.48, -110.76")
    end

    it "asks for a first pin when there's no location at all" do
      subject = presenter(place: nil)

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

  describe "the race shortcuts" do
    # 2026-08-20 18:00 UTC == 12:00 MDT, so "today" in America/Denver is August 20, 2026.
    around { |example| travel_to(Time.utc(2026, 8, 20, 18, 0, 0)) { example.run } }

    # ⚠️ `on:` becomes a **zoned** 9am timestamp, like Contentful's own dates. `Time.parse` reads a
    # bare "2026-10-10" in the *machine's* zone, so a UTC CI box resolves it to the day before in
    # America/Denver and every date here slides back one.
    def event(title:, on: nil, date: nil, going: true, location: "Kona, Hawaii",
              lat: 19.64, lon: -155.99)
      date ||= ActiveSupport::TimeZone[time_zone].parse("#{on} 09:00").iso8601
      coordinates = lat && lon ? { lat: lat, lon: lon } : nil
      DeepOstruct.wrap(title: title, date: date, going: going, location: location,
                       coordinates: coordinates)
    end

    it "lists the confirmed races still ahead, soonest first" do
      subject = presenter(events: [
        event(title: "Kona", on: "2026-10-10"),
        event(title: "Boulder", on: "2026-09-01"),
        event(title: "Last year's", on: "2025-10-10")
      ])

      expect(subject.races.map(&:title)).to eq([ "Boulder", "Kona" ])
    end

    # ⚠️ Not EventsHelper#upcoming_races: that caps the widget's list at three or four. Every race
    # ahead is a place you might be.
    it "lists more than the widget would" do
      events = (1..6).map { |n| event(title: "Race #{n}", on: "2026-09-0#{n}") }

      expect(presenter(events: events).races.size).to eq(6)
    end

    it "keeps a race happening today" do
      subject = presenter(events: [ event(title: "Today", on: "2026-08-20") ])

      expect(subject.races.map(&:title)).to eq([ "Today" ])
    end

    it "drops races that aren't confirmed" do
      subject = presenter(events: [ event(title: "Maybe", on: "2026-09-01", going: false) ])

      expect(subject.races).to be_empty
    end

    # A button with nowhere to send the map isn't a shortcut.
    it "drops races without coordinates" do
      subject = presenter(events: [ event(title: "Unplaced", on: "2026-09-01", lat: nil, lon: nil) ])

      expect(subject.races).to be_empty
    end

    it "drops races with a date it can't read" do
      subject = presenter(events: [ event(title: "Someday", date: "whenever") ])

      expect(subject.races).to be_empty
    end

    it "carries the coordinates and a formatted date for the button" do
      subject = presenter(events: [ event(title: "Kona", on: "2026-10-10") ])
      race = subject.races.first

      expect(race.latitude).to eq(19.64)
      expect(race.longitude).to eq(-155.99)
      expect(race.place).to eq("Kona, Hawaii")
      expect(race.on).to eq("October 10, 2026")
    end
  end
end
