require 'httparty'
require 'active_support/all'
require 'icalendar'

# The TrainerRoad class interfaces with a TrainerRoad calendar to fetch workout details.
class TrainerRoad
  CALENDAR_URL = ENV['TRAINERROAD_CALENDAR_URL']
  DISCIPLINE_ORDER = { "Swim" => 1, "Bike" => 2, "Run" => 3 }

  # Initializes the TrainerRoad class with a specified timezone.
  # @param timezone [String] The timezone for the workout times.
  # @return [TrainerRoad] The instance of the TrainerRoad class.
  def initialize(timezone = "America/Denver")
    @timezone = timezone
  end

  # Fetches the workouts for the current day from the TrainerRoad calendar.
  # @return [Array<Hash>, nil] An array of today's workouts, or nil if no data is available.
  def workouts
    return if CALENDAR_URL.blank?

    cache_key = "trainerroad:workouts:#{@timezone}:#{CALENDAR_URL.parameterize}"
    data = $redis.get(cache_key)

    return JSON.parse(data) if data.present?

    response = HTTParty.get(CALENDAR_URL)
    return [] unless response.success?

    calendars = Icalendar::Calendar.parse(response.body)
    calendar = calendars.first
    today = Time.current.in_time_zone(@timezone).to_date

    todays_events = calendar.events.select do |event|
      event.dtstart.to_datetime.to_date == today
    end

    workouts = todays_events.map do |event|
      parse_workout(event)
    end

    workouts = workouts.compact.sort_by { |w| DISCIPLINE_ORDER[w[:discipline]] }

    $redis.setex(cache_key, 5.minutes, workouts.to_json)

    workouts
  end

  # Saves the current day's workouts to a JSON file.
  def save_data
    data = {
      workouts: workouts
    }
    File.open('data/trainerroad.json', 'w') { |f| f << data.to_json }
  end

  private

  # Parses a workout event to extract relevant details.
  # @param event [Icalendar::Event] The calendar event representing a workout.
  # @return [Hash, nil] A hash with the workout's details, including :duration, :name,
  #         :discipline, :summary, and :description. Returns nil if the event summary
  #         does not match the expected format or if critical information is missing.
  def parse_workout(event)
    match_data = /(\d+:\d+) - (.+)/.match(event.summary)
    return nil if match_data.blank?

    duration = match_data[1]
    name = match_data[2]
    discipline = determine_discipline(name)

    summary = human_readable_summary(duration, discipline)
    description = event.description.sub(/.*?Description: /, '')

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

    if total_minutes <= 90
      description_duration = "#{total_minutes}-minute"
    else
      description_duration = duration
    end

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
