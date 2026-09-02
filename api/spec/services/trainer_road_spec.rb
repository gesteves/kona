require "rails_helper"

RSpec.describe TrainerRoad do
  subject(:service) { described_class.new("America/Denver", calendar_url: calendar_url) }

  let(:calendar_url) { "https://example.test/calendar.ics" }

  # #planned_workouts and #workouts share this, because both parse the same feed.
  def ics(events)
    body = events.map.with_index do |event, index|
      lines = [ "BEGIN:VEVENT", "UID:#{index}" ]
      if event[:all_day]
        lines << "DTSTART;VALUE=DATE:#{event.fetch(:date, '20260709')}"
      else
        lines << "DTSTART:#{event.fetch(:start, '20260709T170000Z')}"
        lines << "DTEND:#{event.fetch(:end, '20260709T180000Z')}"
      end
      lines << "SUMMARY:#{event[:summary]}"
      lines << "DESCRIPTION:#{event[:description]}" if event[:description]
      lines << "END:VEVENT"
      lines.join("\n")
    end.join("\n")

    "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Test//EN\n#{body}\nEND:VCALENDAR"
  end

  def stub_calendar(events)
    allow(HTTParty).to receive(:get).and_return(
      instance_double(HTTParty::Response, success?: true, body: ics(events))
    )
  end

  describe "#connected?" do
    it "is true with a stored feed" do
      expect(service).to be_connected
    end

    context "when no feed is connected" do
      let(:calendar_url) { nil }

      it "is false" do
        expect(service).not_to be_connected
      end
    end
  end

  # ⚠️ A URL with a typing error, stored with no check, makes each rest-day check and each
  # planned-workout line fail with no message. The admin form exists to show that failure.
  describe "#connect!" do
    before { allow(TrainerRoadCredentials).to receive(:store) }

    it "stores the URL when the feed parses as a calendar" do
      stub_calendar([ { all_day: true, summary: "1:00 - Petit" } ])

      expect(service.connect!).to be(true)
      expect(TrainerRoadCredentials).to have_received(:store).with(calendar_url: calendar_url)
    end

    it "stores nothing when the feed answers with a failure" do
      allow(HTTParty).to receive(:get).and_return(
        instance_double(HTTParty::Response, success?: false, code: 404, body: "")
      )

      expect(service.connect!).to be(false)
      expect(TrainerRoadCredentials).not_to have_received(:store)
    end

    it "stores nothing when the body is not a calendar" do
      allow(HTTParty).to receive(:get).and_return(
        instance_double(HTTParty::Response, success?: true, body: "<html>Sign in</html>")
      )

      expect(service.connect!).to be(false)
      expect(TrainerRoadCredentials).not_to have_received(:store)
    end

    it "stores nothing when the host cannot be reached" do
      allow(HTTParty).to receive(:get).and_raise(SocketError)

      expect(service.connect!).to be(false)
      expect(TrainerRoadCredentials).not_to have_received(:store)
    end

    context "when the form was empty" do
      let(:calendar_url) { nil }

      it "makes no request" do
        allow(HTTParty).to receive(:get)

        expect(service.connect!).to be(false)
        expect(HTTParty).not_to have_received(:get)
      end
    end
  end

  describe "#disconnect!" do
    it "clears the stored URL" do
      allow(TrainerRoadCredentials).to receive(:clear)

      service.disconnect!

      expect(TrainerRoadCredentials).to have_received(:clear)
    end
  end

  describe "#determine_discipline" do
    it { expect(service.send(:determine_discipline, "Run - Easy")).to eq("Run") }
    it { expect(service.send(:determine_discipline, "Swim Endurance")).to eq("Swim") }
    it { expect(service.send(:determine_discipline, "Sweet Spot Base")).to eq("Bike") }
    # A name with no discipline is a ride, thus the formatter never gets a nil.
    it { expect(service.send(:determine_discipline, nil)).to eq("Bike") }
  end

  describe "#human_readable_summary" do
    it "spells out durations up to 90 minutes" do
      expect(service.send(:human_readable_summary, "1:00", "Bike")).to eq("60-minute ride")
      expect(service.send(:human_readable_summary, "0:45", "Run")).to eq("45-minute run")
      expect(service.send(:human_readable_summary, "1:30", "Swim")).to eq("90-minute swim")
    end

    it "keeps the H:MM form past 90 minutes and says 'ride' for Bike" do
      expect(service.send(:human_readable_summary, "2:00", "Bike")).to eq("2:00 ride")
    end
  end

  describe "#parse_workout" do
    it "extracts duration, name, discipline, summary, and description" do
      event = double(summary: "1:00 - Petit", description: "Workout of the Week. Description: Sixty minutes of fun.")
      expect(service.send(:parse_workout, event)).to include(
        duration: "1:00",
        name: "Petit",
        discipline: "Bike",
        summary: "60-minute ride",
        description: "Sixty minutes of fun."
      )
    end

    it "returns nil for an event that isn't a workout" do
      expect(service.send(:parse_workout, double(summary: "Rest Day", description: ""))).to be_nil
    end
  end

  describe "#planned_workouts" do
    let(:date) { Date.new(2026, 7, 9) }

    before do
      allow($redis).to receive(:get).and_return(nil)
      allow($redis).to receive(:setex)
    end

    it "returns all-day workouts with the duration prefix stripped and the description cleaned" do
      stub_calendar([ { all_day: true, summary: "2:00 - Gibbs", description: "TSS 120. Description: Two hours of sweet spot." } ])

      workouts = service.planned_workouts(date)

      expect(workouts).to eq([ { name: "Gibbs", sport: "Cycling", description: "TSS 120. Two hours of sweet spot." } ])
    end

    it "excludes all-day events without a duration prefix (annotations, races)" do
      stub_calendar([ { all_day: true, summary: "Rest Day" } ])

      expect(service.planned_workouts(date)).to eq([])
    end

    it "excludes race legs whose stripped name matches a same-day race umbrella" do
      stub_calendar([
        { all_day: true, summary: "Escape from Alcatraz" },
        { all_day: true, summary: "0:45 - Escape from Alcatraz" },
        { all_day: true, summary: "1:00 - Petit" }
      ])

      expect(service.planned_workouts(date).map { |w| w[:name] }).to eq([ "Petit" ])
    end

    it "excludes events on other dates" do
      stub_calendar([ { all_day: true, date: "20260710", summary: "1:00 - Petit" } ])

      expect(service.planned_workouts(date)).to eq([])
    end

    it "filters timed events by their date in the athlete's timezone" do
      # 01:00Z on July 10 is 19:00 on July 9 in Denver.
      stub_calendar([ { summary: "Evening Run Intervals", start: "20260710T010000Z", end: "20260710T020000Z" } ])

      workouts = service.planned_workouts(date)

      expect(workouts.map { |w| w[:name] }).to eq([ "Evening Run Intervals" ])
      expect(workouts.first[:sport]).to eq("Running")
    end

    it "detects sports from keywords, Endless Pool, and the TSS default" do
      stub_calendar([
        { all_day: true, summary: "1:00 - Endless Pool Session" },
        { all_day: true, summary: "0:45 - Tempo Run" },
        { all_day: true, summary: "1:30 - Baxter", description: "TSS 90" }
      ])

      sports = service.planned_workouts(date).map { |w| w[:sport] }

      expect(sports).to contain_exactly("Swimming", "Running", "Cycling")
    end

    context "when no feed is connected" do
      let(:calendar_url) { nil }

      it "returns []" do
        expect(service.planned_workouts(date)).to eq([])
      end
    end

    it "raises on an HTTP failure so callers can degrade explicitly" do
      allow(HTTParty).to receive(:get).and_return(
        instance_double(HTTParty::Response, success?: false, code: 500, body: "boom")
      )
      allow(service).to receive(:report_upstream_error)

      expect { service.planned_workouts(date) }.to raise_error(ApplicationService::HttpError)
    end
  end

  # The weather widget and the Whoop widget call this method, through workout_scheduled? and
  # rest_day?. Both read `.any?` only, thus each change to the events that the code selects changes
  # the text of those widgets.
  describe "#workouts" do
    include ActiveSupport::Testing::TimeHelpers

    # 20:00 on July 9 in America/Denver, which is UTC-6 in July. That is July 10 in UTC.
    around { |example| travel_to(Time.utc(2026, 7, 10, 2, 0, 0)) { example.run } }

    before do
      allow($redis).to receive(:get).and_return(nil)
      allow($redis).to receive(:setex)
    end

    context "when no feed is connected" do
      let(:calendar_url) { nil }

      it "returns nil" do
        expect(service.workouts).to be_nil
      end
    end

    # ⚠️ "Today" is decided inside the read, thus the key must name the day, or the list of the day
    # before stays for the TTL after midnight.
    it "keys the cache on the day in the timezone, and reads the feed with a timeout" do
      stub_calendar([ { all_day: true, date: "20260709", summary: "0:30 - Easy Run" } ])

      service.workouts
      expect($redis).to have_received(:get).with(a_string_starting_with("trainerroad:workouts:America/Denver:2026-07-09:"))
      expect(HTTParty).to have_received(:get).with(calendar_url, hash_including(timeout: described_class::CONNECT_TIMEOUT))

      travel_to(Time.utc(2026, 7, 10, 7, 0, 0))
      service.workouts
      expect($redis).to have_received(:get).with(a_string_starting_with("trainerroad:workouts:America/Denver:2026-07-10:"))
    end

    it "returns today's workouts, sorted swim then bike then run" do
      stub_calendar([
        { all_day: true, date: "20260709", summary: "0:30 - Easy Run" },
        { all_day: true, date: "20260709", summary: "1:00 - Petit" },
        { all_day: true, date: "20260709", summary: "0:45 - Swim Endurance" }
      ])

      expect(service.workouts.map { |w| w[:discipline] }).to eq(%w[Swim Bike Run])
    end

    it "excludes events on other days" do
      stub_calendar([ { all_day: true, date: "20260711", summary: "1:00 - Petit" } ])

      expect(service.workouts).to eq([])
    end

    # ⚠️ This method had one failure: `event.dtstart.to_datetime.to_date` reads a timed event in its
    # own stored offset. Thus this 02:00Z event became July 10 and left the list of July 9, and
    # rest_day? was then true on a day with a workout.
    it "counts a timed evening event on the local day, not the UTC one" do
      stub_calendar([ { start: "20260710T020000Z", end: "20260710T030000Z", summary: "1:00 - Petit" } ])

      expect(service.workouts.map { |w| w[:name] }).to eq([ "Petit" ])
    end

    it "does not count a timed event that is still tomorrow locally" do
      stub_calendar([ { start: "20260711T020000Z", end: "20260711T030000Z", summary: "1:00 - Petit" } ])

      expect(service.workouts).to eq([])
    end

    it "returns [] and reports when the calendar fetch fails" do
      allow(HTTParty).to receive(:get).and_return(
        instance_double(HTTParty::Response, success?: false, code: 500, body: "boom")
      )
      expect(service).to receive(:report_upstream_error)

      expect(service.workouts).to eq([])
    end
  end
end
