require "rails_helper"

# Unit coverage for the events helper. The tricky bits — "is it today?", "is the race in
# progress?", which calendar/tracking icon to show, and how the upcoming-races collection is
# selected and laid out — all hinge on the current date and time, so the clock is frozen to a
# fixed midday in the race timezone (America/Denver) to keep "today" deterministic regardless
# of the machine's own timezone.
#
# `is_daytime?` is weather-derived (covered by the weather specs) and falls back to the system
# clock, so it's stubbed here to isolate the event logic. `icon_svg` is stubbed to echo the
# family/style/id it was asked for, so we can assert which icon each helper picked.
RSpec.describe EventsHelper, type: :helper do
  include ActiveSupport::Testing::TimeHelpers

  # 2026-06-03 18:00 UTC == 2026-06-03 12:00 MDT, so "today" in America/Denver is June 3, 2026.
  around { |example| travel_to(Time.utc(2026, 6, 3, 18, 0, 0)) { example.run } }

  before do
    helper.instance_variable_set(:@time_zone, "America/Denver")
    allow(helper).to receive(:is_daytime?).and_return(true)
    allow(helper).to receive(:icon_svg) { |family, style, id| %(<svg data-icon="#{family}-#{style}-#{id}"></svg>).html_safe }
  end

  # An ISO8601 timestamp at 9am in the race timezone, `days` away from the frozen "today".
  # Zoned (carries an offset) so it parses to an unambiguous instant on any machine.
  def event_date(days)
    (Time.current.in_time_zone("America/Denver") + days.days).change(hour: 9).iso8601
  end

  def build_event(days_from_today: 0, **overrides)
    DeepOstruct.wrap({
      title: "Some Race",
      location: "Boulder, Colorado",
      url: nil,
      tracking_url: nil,
      date: event_date(days_from_today),
      going: true,
      coordinates: { lat: 40.01, lon: -105.27 },
      sys: { id: "evt-#{days_from_today}-#{overrides[:tracking_url] ? 'tracked' : 'plain'}" }
    }.merge(overrides))
  end

  describe "#is_today?" do
    it "is false for a blank event" do
      expect(helper.is_today?(nil)).to be(false)
    end

    it "is true for an event dated today in the race timezone" do
      expect(helper.is_today?(build_event(days_from_today: 0))).to be(true)
    end

    it "is false for a future or past event" do
      expect(helper.is_today?(build_event(days_from_today: 1))).to be(false)
      expect(helper.is_today?(build_event(days_from_today: -1))).to be(false)
    end
  end

  describe "#is_in_progress?" do
    it "is false for a blank event" do
      expect(helper.is_in_progress?(nil)).to be(false)
    end

    it "is true when the event is today, confirmed, and it's daytime" do
      expect(helper.is_in_progress?(build_event(days_from_today: 0))).to be(true)
    end

    it "is false at night even when the event is today and confirmed" do
      allow(helper).to receive(:is_daytime?).and_return(false)
      expect(helper.is_in_progress?(build_event(days_from_today: 0))).to be(false)
    end

    it "is false when the event is today but not confirmed (not going)" do
      expect(helper.is_in_progress?(build_event(days_from_today: 0, going: false))).to be(false)
    end

    it "is false when the event isn't today" do
      expect(helper.is_in_progress?(build_event(days_from_today: 1))).to be(false)
    end
  end

  describe "#todays_race / #is_race_day?" do
    it "returns today's confirmed race and reports a race day" do
      race = build_event(days_from_today: 0)
      helper.instance_variable_set(:@events, [build_event(days_from_today: 5), race])

      expect(helper.todays_race).to eq(race)
      expect(helper.is_race_day?).to be(true)
    end

    it "ignores a today event that isn't confirmed" do
      helper.instance_variable_set(:@events, [build_event(days_from_today: 0, going: false)])

      expect(helper.todays_race).to be_nil
      expect(helper.is_race_day?).to be(false)
    end

    it "reports no race day when nothing is today" do
      helper.instance_variable_set(:@events, [build_event(days_from_today: 3)])

      expect(helper.is_race_day?).to be(false)
    end
  end

  describe "#event_timestamp" do
    it "formats the event's date" do
      event = build_event(days_from_today: 5)
      expected = DateTime.parse(event.date).strftime("%B %-e, %Y")
      expect(helper.event_timestamp(event)).to eq(expected)
    end
  end

  describe "#event_timestamp_tag" do
    it "renders a calendar-check icon and the formatted date, with no highlight" do
      event = build_event(days_from_today: 5)
      tag = helper.event_timestamp_tag(event)
      expect(tag).to include('data-icon="classic-light-calendar-check"')
      expect(tag).to include(DateTime.parse(event.date).strftime("%B %-e, %Y"))
      expect(tag).not_to include("entry__highlight")
    end
  end

  describe "#event_live_tracking_tag" do
    it "returns nil for a blank event" do
      expect(helper.event_live_tracking_tag(nil)).to be_nil
    end

    it "returns nil when the event has no tracking link" do
      expect(helper.event_live_tracking_tag(build_event(days_from_today: 0))).to be_nil
    end

    context "when the event has a tracking link but isn't in progress" do
      let(:tag) { helper.event_live_tracking_tag(build_event(days_from_today: 5, tracking_url: "https://track.example.com")) }

      it "renders a muted, light-icon Live tracking link with no highlight" do
        expect(tag).to include('data-icon="classic-light-signal-stream-slash"')
        expect(tag).to include(">Live tracking</a>")
        expect(tag).to include('href="https://track.example.com"')
        expect(tag).not_to include("entry__highlight")
      end

      it "opens the tracking link safely in a new tab" do
        expect(tag).to include('target="_blank"')
        expect(tag).to include('rel="noopener"')
      end
    end

    context "when the event has a tracking link and is in progress" do
      let(:tag) { helper.event_live_tracking_tag(build_event(days_from_today: 0, tracking_url: "https://track.example.com")) }

      it "renders a highlighted, pulsing (regular-icon) Live tracking link" do
        expect(tag).to include("entry__highlight entry__highlight--live")
        expect(tag).to include('data-icon="classic-regular-signal-stream"')
        expect(tag).to include(">Live tracking</a>")
        expect(tag).to include('href="https://track.example.com"')
      end
    end

    it "is muted (not highlighted) for a tracking link on today's race at night" do
      allow(helper).to receive(:is_daytime?).and_return(false)
      tag = helper.event_live_tracking_tag(build_event(days_from_today: 0, tracking_url: "https://track.example.com"))
      expect(tag).to include('data-icon="classic-light-signal-stream-slash"')
      expect(tag).not_to include("entry__highlight")
    end
  end

  describe "#is_close?" do
    it "is false for a blank event" do
      expect(helper.is_close?(nil)).to be(false)
    end

    it "is true for an event today or within the next 10 days" do
      expect(helper.is_close?(build_event(days_from_today: 0))).to be(true)
      expect(helper.is_close?(build_event(days_from_today: 10))).to be(true)
    end

    it "is false for an event more than 10 days out or in the past" do
      expect(helper.is_close?(build_event(days_from_today: 11))).to be(false)
      expect(helper.is_close?(build_event(days_from_today: -1))).to be(false)
    end
  end

  describe "#upcoming_races" do
    it "is empty when there are no events" do
      helper.instance_variable_set(:@events, [])
      expect(helper.upcoming_races).to eq([])
    end

    it "keeps only confirmed future-or-today events, soonest first" do
      past = build_event(days_from_today: -2)
      cancelled = build_event(days_from_today: 4, going: false)
      today = build_event(days_from_today: 0)
      soon = build_event(days_from_today: 3)
      helper.instance_variable_set(:@events, [soon, past, cancelled, today])

      expect(helper.upcoming_races).to eq([today, soon])
    end

    it "shows up to four when the next race is featured (within 10 days)" do
      events = [0, 3, 8, 20, 25].map { |d| build_event(days_from_today: d) }
      helper.instance_variable_set(:@events, events.shuffle)

      expect(helper.upcoming_races.size).to eq(4)
    end

    it "shows up to three when the next race is more than 10 days out" do
      events = [15, 18, 22, 25].map { |d| build_event(days_from_today: d) }
      helper.instance_variable_set(:@events, events.shuffle)

      expect(helper.upcoming_races.size).to eq(3)
    end
  end

  describe "#is_next? / #is_featured?" do
    it "marks the soonest upcoming race as next" do
      first = build_event(days_from_today: 0)
      second = build_event(days_from_today: 5)
      helper.instance_variable_set(:@events, [second, first])

      expect(helper.is_next?(first)).to be(true)
      expect(helper.is_next?(second)).to be(false)
    end

    it "features the next race only when it's close" do
      near = build_event(days_from_today: 0)
      helper.instance_variable_set(:@events, [near])
      expect(helper.is_featured?(near)).to be(true)

      far = build_event(days_from_today: 20)
      helper.instance_variable_set(:@events, [far])
      expect(helper.is_featured?(far)).to be(false)
    end
  end

  describe "#event_collection_variant" do
    def with_events(days)
      helper.instance_variable_set(:@events, days.map { |d| build_event(days_from_today: d) })
    end

    it "is single for one race" do
      with_events([0])
      expect(helper.event_collection_variant).to eq("single")
    end

    it "is single for two races when the first is featured" do
      with_events([0, 5])
      expect(helper.event_collection_variant).to eq("single")
    end

    it "is halves for two races when none is featured" do
      with_events([15, 18])
      expect(helper.event_collection_variant).to eq("halves")
    end

    it "is halves for three races when the first is featured" do
      with_events([0, 5, 8])
      expect(helper.event_collection_variant).to eq("halves")
    end

    it "is thirds for three races when none is featured" do
      with_events([15, 18, 22])
      expect(helper.event_collection_variant).to eq("thirds")
    end

    it "is thirds for four races" do
      with_events([0, 3, 8, 9])
      expect(helper.event_collection_variant).to eq("thirds")
    end
  end
end
