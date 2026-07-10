require "icalendar"

# Fetches today's workouts from a TrainerRoad calendar (an iCalendar feed). Used to
# decide whether today is a rest day, which tweaks the Whoop strain label.
class TrainerRoad < ApplicationService
  CALENDAR_URL = ENV["TRAINERROAD_CALENDAR_URL"]
  DISCIPLINE_ORDER = { "Swim" => 1, "Bike" => 2, "Run" => 3 }

  # @param timezone [String] The timezone used to determine "today".
  def initialize(timezone = "America/Denver")
    @timezone = timezone
  end

  # Fetches today's workouts from the TrainerRoad calendar, caching them in Redis for 5 minutes.
  # @return [Array<Hash>, nil] An array of today's workouts, or nil if no feed is configured.
  def workouts
    return if CALENDAR_URL.blank?

    cache_key = "trainerroad:workouts:#{@timezone}:#{CALENDAR_URL.parameterize}"
    cached_json(cache_key, expires_in: 5.minutes) do
      response = HTTParty.get(CALENDAR_URL)
      unless response.success?
        report_upstream_error("HTTP #{response.code}", context: "TrainerRoad calendar", status: response.code)
        next []
      end

      calendar = Icalendar::Calendar.parse(response.body).first
      today = Time.current.in_time_zone(@timezone).to_date

      todays_events = calendar.events.select do |event|
        event.dtstart.to_datetime.to_date == today
      end

      todays_events.map { |event| parse_workout(event) }
                   .compact
                   .sort_by { |w| DISCIPLINE_ORDER[w[:discipline]] }
    end
  end

  # Fetches the planned workouts for a calendar date, for matching against completed
  # activities (the description generator's 🗓️ headline). Mirrors domestique's
  # getPlannedWorkouts filtering:
  #   - All-day (DATE) events use their floating calendar date, must carry a "H:MM - Name"
  #     duration prefix, and are excluded when they're a race leg (their stripped name
  #     matches a same-day all-day event *without* a prefix — the race umbrella).
  #   - Timed (DATE-TIME) events are date-filtered in the athlete's timezone and must have
  #     a plausible duration (more than 0, less than 24 hours).
  # @param date [Date] The calendar date to fetch.
  # @param timezone [String] IANA timezone for interpreting timed events.
  # @return [Array<Hash>] Hashes with :name (duration prefix stripped), :sport (normalized
  #   activity type), and :description (cleaned), cached for 5 minutes.
  def planned_workouts(date, timezone: @timezone)
    return [] if CALENDAR_URL.blank?

    cache_key = "trainerroad:planned:#{date}:#{timezone}:#{CALENDAR_URL.parameterize}"
    cached_json(cache_key, expires_in: 5.minutes) do
      events = fetch_calendar_events
      events_on_date = events.select { |event| event_on_date?(event, date, timezone) }

      # Race umbrellas: all-day events without a duration prefix. Their name marks same-day
      # "H:MM - Name" entries as race legs, which aren't workouts.
      race_names = events_on_date.select { |e| all_day?(e) && parse_duration_prefix(e.summary.to_s.strip).nil? }
                                 .map { |e| e.summary.to_s.strip }
                                 .to_set

      events_on_date.select { |event| planned_workout?(event, race_names) }
                    .map { |event| normalize_planned_workout(event) }
    end
  end

  private

  # Fetches and parses all VEVENTs from the calendar feed, raising on HTTP failure so the
  # description generator's rescue can log it (a missing feed shouldn't 500 the webhook job;
  # the caller treats errors as "no planned workouts").
  # @return [Array<Icalendar::Event>]
  def fetch_calendar_events
    response = HTTParty.get(CALENDAR_URL)
    unless response.success?
      report_upstream_error("HTTP #{response.code}", context: "TrainerRoad calendar", status: response.code)
      raise ApplicationService::HttpError.new(response.code, response.body, CALENDAR_URL)
    end

    calendar = Icalendar::Calendar.parse(response.body).first
    calendar ? calendar.events.select { |event| event.dtstart.present? && event.summary.present? } : []
  end

  # Whether the event falls on the given calendar date. All-day events carry a floating
  # date (that day regardless of timezone); timed events are converted to the athlete's
  # timezone first, so a 5 PM local event near midnight UTC lands on the right day.
  def event_on_date?(event, date, timezone)
    if all_day?(event)
      event.dtstart.to_date == date
    else
      event.dtstart.to_time.in_time_zone(timezone).to_date == date
    end
  end

  # All-day events are parsed by icalendar as DATE values (no time component).
  def all_day?(event)
    event.dtstart.is_a?(Icalendar::Values::Date)
  end

  # Whether the event is a planned workout (vs. an annotation, phase marker, or race leg).
  def planned_workout?(event, race_names)
    summary = event.summary.to_s.strip

    if all_day?(event)
      return false if parse_duration_prefix(summary).nil?

      # "0:45 - Escape from Alcatraz" alongside an all-day "Escape from Alcatraz" is a race
      # leg, not a workout.
      !race_names.include?(strip_duration_prefix(summary))
    else
      return false if event.dtend.blank?

      duration_minutes = (event.dtend.to_time - event.dtstart.to_time) / 60
      duration_minutes.positive? && duration_minutes < 1440
    end
  end

  # @return [Hash] The planned workout's :name, :sport, and :description.
  def normalize_planned_workout(event)
    summary = event.summary.to_s.strip

    {
      name: strip_duration_prefix(summary),
      sport: detect_sport(summary, raw_description(event)),
      description: clean_description(raw_description(event))
    }
  end

  # @return [String, nil] The event's description, tolerating icalendar's array values.
  def raw_description(event)
    description = event.description.is_a?(Array) ? event.description.first : event.description
    description&.to_s
  end

  # Parses the "H:MM - " duration prefix into minutes, or nil when absent.
  def parse_duration_prefix(name)
    match = name.match(/\A(\d{1,2}):(\d{2})\s*[-–—]/)
    return if match.nil?

    (match[1].to_i * 60) + match[2].to_i
  end

  # Strips the "H:MM - " duration prefix from a workout name (e.g. "2:00 - Gibbs" → "Gibbs").
  def strip_duration_prefix(name)
    match = name.match(/\A(\d{1,2}):(\d{2})\s*[-–—]\s*(.+)\z/m)
    match ? match[3] : name
  end

  # Removes TrainerRoad's "Description:" label from an event description.
  # @return [String, nil]
  def clean_description(description)
    description&.sub(/\s*Description:/i, "")&.strip.presence
  end

  # Detects the workout's normalized sport, mirroring domestique's detectSport: "Endless
  # Pool" workouts are swims, then the full name is normalized, then word-boundary keywords
  # are scanned, then a "TSS…" description implies cycling, defaulting to Cycling
  # (TrainerRoad is a cycling platform).
  SPORT_KEYWORDS = %w[run running swim swimming ride cycling bike hike hiking ski skiing row rowing].freeze

  def detect_sport(name, description)
    return "Swimming" if name.match?(/\bendless pool\b/i)

    normalized = ActivityMatcher.normalize_type(name)
    return normalized if normalized != "Other"

    name_lower = name.downcase
    SPORT_KEYWORDS.each do |keyword|
      next unless name_lower.match?(/\b#{keyword}\b/)

      keyword_normalized = ActivityMatcher.normalize_type(keyword)
      return keyword_normalized if keyword_normalized != "Other"
    end

    return "Cycling" if description.to_s.start_with?("TSS")

    "Cycling"
  end

  # Parses a workout event to extract relevant details.
  # @param event [Icalendar::Event] The calendar event representing a workout.
  # @return [Hash, nil] A hash with the workout's details, or nil if the event summary
  #   does not match the expected format.
  def parse_workout(event)
    match_data = /(\d+:\d+) - (.+)/.match(event.summary)
    return nil if match_data.blank?

    duration = match_data[1]
    name = match_data[2]
    discipline = determine_discipline(name)

    summary = human_readable_summary(duration, discipline)
    description_text = event.description.is_a?(Array) ? event.description.first.to_s : event.description.to_s
    description = description_text.sub(/.*?Description: /, "")

    {
      duration: duration,
      name: name,
      discipline: discipline,
      summary: summary,
      description: description
    }
  end

  # Converts workout duration and discipline into a human-readable summary.
  # @param duration [String] The duration of the workout.
  # @param discipline [String] The discipline of the workout (e.g., Bike, Run, Swim).
  # @return [String] A human-readable summary of the workout.
  def human_readable_summary(duration, discipline)
    hours, minutes = duration.split(":").map(&:to_i)
    total_minutes = (hours * 60) + minutes

    description_duration = total_minutes <= 90 ? "#{total_minutes}-minute" : duration
    suffix = discipline == "Bike" ? "ride" : discipline.downcase

    "#{description_duration} #{suffix}"
  end

  # Determines the discipline of the workout based on its name.
  # @param name [String] The name of the workout.
  # @return [String] The determined discipline ('Bike', 'Run', or 'Swim').
  def determine_discipline(name)
    return if name.blank?
    return "Run" if name.include?("Run")
    return "Swim" if name.include?("Swim")
    "Bike"
  end
end
