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
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
  end

  # Fetches the workouts for the current day from the TrainerRoad calendar.
  # @return [Array<Hash>, nil] An array of today's workouts, or nil if no data is available.
  def workouts
    return if CALENDAR_URL.blank?

    cache_key = "trainerroad:workouts:#{@timezone}:#{CALENDAR_URL.parameterize}"
    data = @redis.get(cache_key)

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
      parse_workout(event.summary)
    end

    workouts = workouts.compact.sort_by { |w| DISCIPLINE_ORDER[w[:discipline]] }

    @redis.setex(cache_key, 1.hour, workouts.to_json)

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

  # Parses the workout summary to extract workout details.
  # @param summary [String] The summary of the workout event.
  # @return [Hash, nil] The parsed workout details or nil if parsing fails.
  def parse_workout(summary)
    match_data = /(\d+:\d+) - (.+)/.match(summary)
    return nil if match_data.blank?

    duration = match_data[1]
    name = match_data[2]
    discipline = determine_discipline(name)

    description = human_readable_description(duration, discipline)

    {
      duration: duration,
      name: name,
      discipline: discipline,
      description: description
    }
  end

  # Converts workout duration and discipline into a human-readable format.
  # @param duration [String] The duration of the workout.
  # @param discipline [String] The discipline of the workout (e.g., Bike, Run, Swim).
  # @return [String] A human-readable description of the workout.
  def human_readable_description(duration, discipline)
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
