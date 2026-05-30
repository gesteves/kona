require "httparty"
require "icalendar"

# Fetches today's workouts from a TrainerRoad calendar (an iCalendar feed). Used to
# decide whether today is a rest day, which tweaks the Whoop strain label.
class TrainerRoad
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
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    response = HTTParty.get(CALENDAR_URL)
    return [] unless response.success?

    calendars = Icalendar::Calendar.parse(response.body)
    calendar = calendars.first
    today = Time.current.in_time_zone(@timezone).to_date

    todays_events = calendar.events.select do |event|
      event.dtstart.to_datetime.to_date == today
    end

    workouts = todays_events.map { |event| parse_workout(event) }
    workouts = workouts.compact.sort_by { |w| DISCIPLINE_ORDER[w[:discipline]] }

    $redis.setex(cache_key, 5.minutes, workouts.to_json)

    workouts
  end

  private

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
