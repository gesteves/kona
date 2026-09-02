require "icalendar"

# Reads the planned workouts from a TrainerRoad iCalendar feed, for the rest-day check and for the
# planned-workout line that the description generator writes.
class TrainerRoad < ApplicationService
  DISCIPLINE_ORDER = { "Swim" => 1, "Bike" => 2, "Run" => 3 }

  # The timeout of the check that #connect! makes. That action runs in a request with a 20-second
  # rack-timeout, and that timeout raises an exception that `rescue_with` does not catch.
  CONNECT_TIMEOUT = 10

  # The feed that the owner connected. The Connected apps page reads it.
  # @return [String, nil]
  attr_reader :calendar_url

  # @param timezone [String] The timezone for "today".
  # @param calendar_url [String, nil] The feed. The default is the URL that the admin stored.
  def initialize(timezone = "America/Denver", calendar_url: TrainerRoadCredentials.fetch)
    @timezone = timezone
    @calendar_url = calendar_url
  end

  # @return [Boolean] True if a feed is connected.
  def connected? = @calendar_url.present?

  # Checks the feed of this instance and stores its URL.
  #
  # ⚠️ It gets the feed and parses it before it stores the URL. A URL with a typing error, that the
  # code stores with no check, makes each rest-day check and each planned-workout line fail, and it
  # gives no message.
  # @return [Boolean] True if the feed answered with a calendar and the code stored the URL.
  def connect!
    return false if @calendar_url.blank?
    return false unless calendar_feed?

    TrainerRoadCredentials.store(calendar_url: @calendar_url)
    true
  end

  # Removes the stored feed.
  # @return [void]
  def disconnect! = TrainerRoadCredentials.clear

  # The workouts of today. The cache holds them for 5 minutes.
  # @return [Array<Hash>, nil] The workouts, or nil if there is no feed in the configuration.
  def workouts
    return if @calendar_url.blank?

    cache_key = "trainerroad:workouts:#{@timezone}:#{calendar_version}"
    cached_json(cache_key, expires_in: 5.minutes) do
      response = HTTParty.get(@calendar_url)
      unless response.success?
        report_upstream_error("HTTP #{response.code}", context: "TrainerRoad calendar", status: response.code)
        next []
      end

      calendar = Icalendar::Calendar.parse(response.body).first
      today = Time.current.in_time_zone(@timezone).to_date

      # ⚠️ This goes through event_on_date?, which changes a timed event into @timezone first. A
      # comparison of `event.dtstart.to_datetime.to_date` uses the stored offset of the event, thus
      # an event in the evening goes to the next day. Both consumers read only `workouts.any?`,
      # thus that changes workout_scheduled? and rest_day? with no message.
      todays_events = calendar.events.select do |event|
        event.dtstart.present? && event_on_date?(event, today, @timezone)
      end

      todays_events.map { |event| parse_workout(event) }
                   .compact
                   .sort_by { |w| DISCIPLINE_ORDER.fetch(w[:discipline], DISCIPLINE_ORDER.size) }
    end
  end

  # The planned workouts for a date, to compare with the completed activities. An all-day event
  # must have a "H:MM - Name" duration at the start, and the code removes it if it is part of a
  # race. A timed event must have a duration that is possible. The cache holds this for 5 minutes.
  # @param date [Date] The calendar date.
  # @param timezone [String] The IANA timezone for a timed event.
  # @return [Array<Hash>] Hashes with :name, :sport, and :description.
  def planned_workouts(date, timezone: @timezone)
    return [] if @calendar_url.blank?

    cache_key = "trainerroad:planned:#{date}:#{timezone}:#{calendar_version}"
    cached_json(cache_key, expires_in: 5.minutes) do
      events = fetch_calendar_events
      events_on_date = events.select { |event| event_on_date?(event, date, timezone) }

      # A race is an all-day event with no duration at the start. Its name is what marks the
      # entries with a duration on the same day as parts of the race, and not as workouts.
      race_names = events_on_date.select { |e| all_day?(e) && parse_duration_prefix(e.summary.to_s.strip).nil? }
                                 .map { |e| e.summary.to_s.strip }
                                 .to_set

      events_on_date.select { |event| planned_workout?(event, race_names) }
                    .map { |event| normalize_planned_workout(event) }
    end
  end

  private

  # ⚠️ This is a digest, and not the URL. A TrainerRoad iCal URL ends with a GUID that *is* the
  # credential, and `parameterize` keeps it. That put the full token in key names that
  # `redis-cli KEYS`, the Redis stats of the Sidekiq UI, and each slowlog or error report with a
  # key can show. A digest also changes the cache when the URL changes.
  # @return [String] An 8-character digest of the calendar URL.
  def calendar_version
    cache_version(@calendar_url)
  end

  # Gets the feed one time, to know that the URL names a true calendar.
  # @return [Boolean] True if the feed answered and it parses as an iCalendar.
  def calendar_feed?
    response = HTTParty.get(@calendar_url, timeout: CONNECT_TIMEOUT)
    return false unless response.success?

    !Icalendar::Calendar.parse(response.body).first.nil?
  rescue StandardError
    false
  end

  # Gets and parses each VEVENT in the feed.
  # @return [Array<Icalendar::Event>]
  # @raise [ApplicationService::HttpError] If it fails. The caller counts that as "no planned
  #   workouts" and does not stop the job.
  def fetch_calendar_events
    response = HTTParty.get(@calendar_url)
    unless response.success?
      report_upstream_error("HTTP #{response.code}", context: "TrainerRoad calendar", status: response.code)
      raise ApplicationService::HttpError.new(response.code, response.body, @calendar_url)
    end

    calendar = Icalendar::Calendar.parse(response.body).first
    calendar ? calendar.events.select { |event| event.dtstart.present? && event.summary.present? } : []
  end

  # Tells if an event is on a date. An all-day event has a date with no zone. The code changes a
  # timed event into the timezone of the athlete first, thus an event in the evening near midnight
  # UTC goes to the correct day.
  def event_on_date?(event, date, timezone)
    if all_day?(event)
      event.dtstart.to_date == date
    else
      event.dtstart.to_time.in_time_zone(timezone).to_date == date
    end
  end

  # icalendar parses an all-day event as a DATE value, with no time.
  def all_day?(event)
    event.dtstart.is_a?(Icalendar::Values::Date)
  end

  # Tells if an event is a planned workout, and not a note, a phase marker, or part of a race.
  def planned_workout?(event, race_names)
    summary = event.summary.to_s.strip

    if all_day?(event)
      return false if parse_duration_prefix(summary).nil?

      # An entry with a duration beside an all-day event with the same name is part of a race.
      !race_names.include?(strip_duration_prefix(summary))
    else
      return false if event.dtend.blank?

      duration_minutes = (event.dtend.to_time - event.dtstart.to_time) / 60
      duration_minutes.positive? && duration_minutes < 1440
    end
  end

  # @return [Hash] The :name, the :sport, and the :description of the planned workout.
  def normalize_planned_workout(event)
    summary = event.summary.to_s.strip

    {
      name: strip_duration_prefix(summary),
      sport: detect_sport(summary, raw_description(event)),
      description: clean_description(raw_description(event))
    }
  end

  # @return [String, nil] The description of the event. It accepts the array values of
  #   icalendar.
  def raw_description(event)
    description = event.description.is_a?(Array) ? event.description.first : event.description
    description&.to_s
  end

  # Changes the "H:MM - " duration at the start into minutes, or gives nil if it is absent.
  def parse_duration_prefix(name)
    match = name.match(/\A(\d{1,2}):(\d{2})\s*[-–—]/)
    return if match.nil?

    (match[1].to_i * 60) + match[2].to_i
  end

  # Removes the "H:MM - " duration from the start of a workout name. For example, "2:00 - Gibbs"
  # becomes "Gibbs".
  def strip_duration_prefix(name)
    match = name.match(/\A(\d{1,2}):(\d{2})\s*[-–—]\s*(.+)\z/m)
    match ? match[3] : name
  end

  # Removes the TrainerRoad "Description:" label from an event description.
  # @return [String, nil]
  def clean_description(description)
    description&.sub(/\s*Description:/i, "")&.strip.presence
  end

  # Finds the sport of a workout, in this order: "Endless Pool" means swimming, then the code
  # corrects the full name, then it looks for keywords, then a description with "TSS…" means
  # cycling. The default is cycling, because TrainerRoad is a cycling platform.
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

  # Parses a workout event and gets the necessary data.
  # @param event [Icalendar::Event] The calendar event for a workout.
  # @return [Hash, nil] A hash with the data of the workout, or nil if the summary of the event
  #   does not have the correct format.
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

  # Changes the duration and the discipline of a workout into a readable summary.
  # @param duration [String] The duration of the workout.
  # @param discipline [String] The discipline of the workout, for example Bike, Run, or Swim.
  # @return [String] A readable summary of the workout.
  def human_readable_summary(duration, discipline)
    hours, minutes = duration.split(":").map(&:to_i)
    total_minutes = (hours * 60) + minutes

    description_duration = total_minutes <= 90 ? "#{total_minutes}-minute" : duration
    suffix = discipline == "Bike" ? "ride" : discipline.downcase

    "#{description_duration} #{suffix}"
  end

  # Finds the discipline of the workout from its name.
  # @param name [String] The name of the workout.
  # @return [String] The discipline: 'Bike', 'Run', or 'Swim'.
  def determine_discipline(name)
    return if name.blank?
    return "Run" if name.include?("Run")
    return "Swim" if name.include?("Swim")
    "Bike"
  end
end
