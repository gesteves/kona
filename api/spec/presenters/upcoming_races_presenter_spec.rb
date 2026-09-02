require "rails_helper"

# The tests for the decisions of the races widget: which races go in the list, when the first race is
# a featured race and gets the race-day weather, when it is the race of today, and the rule that
# removes the featured state when the weather of a featured event is not available. The date
# calculations, that is, upcoming_races, featured?, and today?, are in events_helper_spec. This file
# gives the weather fetch as a double, thus no upstream fetch occurs.
RSpec.describe UpcomingRacesPresenter do
  include ActiveSupport::Testing::TimeHelpers

  # 2026-06-03 18:00 UTC is 2026-06-03 12:00 MDT, thus "today" in America/Denver is June 3, 2026.
  around { |example| travel_to(Time.utc(2026, 6, 3, 18, 0, 0)) { example.run } }

  let(:time_zone) { "America/Denver" }
  let(:weather) { instance_double(EventWeatherPresenter, forecast: DeepOstruct.wrap(condition_code: "Clear")) }
  # The caller gives the weather fetch, thus no stub of RaceDayWeather is necessary.
  let(:weather_for) { instance_double(Proc, call: weather) }

  def build_event(days_from_today:, **overrides)
    date = (Time.current.in_time_zone(time_zone) + days_from_today.days).change(hour: 9).iso8601
    DeepOstruct.wrap({
      title: "Some Race",
      date: date,
      going: true,
      sys: { id: "evt-#{days_from_today}" }
    }.merge(overrides))
  end

  def presenter_for(events)
    described_class.new(events: events, time_zone: time_zone, weather_for: weather_for)
  end

  it "is empty (and fetches no weather) when nothing is upcoming" do
    presenter = presenter_for([ build_event(days_from_today: -5) ])
    expect(presenter.races).to eq([])
    expect(weather_for).not_to have_received(:call)
  end

  context "when the next race is close but not today" do
    let(:presenter) { presenter_for([ build_event(days_from_today: 3), build_event(days_from_today: 20) ]) }

    it "features it with its race-day weather, with no today's-race section" do
      expect(presenter.featured.sys.id).to eq("evt-3")
      expect(presenter.event_weather).to eq(weather)
      expect(presenter.todays_race).to be_nil
      expect(presenter.other_races).to be_nil
    end

    it "marks only the featured event and reports a featured layout variant" do
      expect(presenter.featured_event?(presenter.races.first)).to be(true)
      expect(presenter.featured_event?(presenter.races.last)).to be(false)
      # Two races, and the first one is a featured race. The layout is single, because the featured
      # card takes the full row.
      expect(presenter.variant).to eq("single")
    end
  end

  context "on race day" do
    let(:presenter) do
      presenter_for([ build_event(days_from_today: 0), build_event(days_from_today: 5), build_event(days_from_today: 8) ])
    end

    it "splits today's race from the other upcoming races" do
      expect(presenter.todays_race.sys.id).to eq("evt-0")
      expect(presenter.other_races.map { |e| e.sys.id }).to eq(%w[evt-5 evt-8])
      expect(presenter.other_races_variant).to eq("halves")
    end

    it "keeps today's race featured even without weather" do
      allow(weather).to receive(:forecast).and_return(nil)
      expect(presenter.todays_race).to be_present
      expect(presenter.races.size).to eq(3)
    end
  end

  context "when a featured (not-today) event has no weather to show" do
    let(:events) { [ 3, 5, 8, 9 ].map { |d| build_event(days_from_today: d) } }

    it "demotes it to a regular race and trims to the non-featured count" do
      allow(weather).to receive(:forecast).and_return(nil)
      presenter = presenter_for(events)

      expect(presenter.featured).to be_nil
      expect(presenter.event_weather).to be_nil
      expect(presenter.races.size).to eq(3)
      expect(presenter.variant).to eq("thirds")
    end
  end

  context "when the next race is more than 10 days out" do
    it "features nothing and fetches no weather" do
      presenter = presenter_for([ build_event(days_from_today: 15), build_event(days_from_today: 20) ])

      expect(presenter.featured).to be_nil
      expect(presenter.races.size).to eq(2)
      expect(weather_for).not_to have_received(:call)
      expect(presenter.variant).to eq("halves")
    end
  end
end
