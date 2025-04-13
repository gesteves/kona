require 'httparty'
require 'active_support/all'
require 'icalendar'

# The Runna class interfaces with a Runna calendar to fetch workout details.
class Runna
  CALENDAR_URL = ENV['RUNNA_CALENDAR_URL']

  # Initializes the Runna class with a specified timezone.
  # @param timezone [String] The timezone for the workout times.
  # @return [Runna] The instance of the Runna class.
  def initialize(timezone = "America/Denver")
    @timezone = timezone
  end

  # Fetches the workouts for the current day from the Runna calendar.
  # @return [Array<Hash>, nil] An array of today's workouts, or nil if no data is available.
  def workouts
    return if CALENDAR_URL.blank?

    cache_key = "runna:workouts:#{@timezone}:#{CALENDAR_URL.parameterize}"
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

    workouts = workouts.compact.sort_by { |w| w[:name] }

    $redis.setex(cache_key, 5.minutes, workouts.to_json)

    workouts
  end

  # Saves the current day's workouts to a JSON file.
  def save_data
    data = {
      workouts: workouts
    }
    File.open('data/runna.json', 'w') { |f| f << data.to_json }
  end

  private

  # Parses a workout event to extract relevant details.
  # @param event [Icalendar::Event] The calendar event representing a workout.
  # @return [Hash, nil] A hash with the workout's details.
  def parse_workout(event)
    return nil if event.summary.blank? || event.description.blank?

    # Remove emoji and extract just the name before the "•"
    raw_name = event.summary.strip
    name_part = raw_name.sub(/^(\p{Emoji_Presentation}|\p{So})\s*/, '') # remove emoji
    name = name_part.split("•").first.strip

    # Parse first line of the description
    description_lines = event.description.lines.map(&:strip).reject(&:blank?)
    header_line = description_lines.first
    type_of_run, distance_text, _ = header_line.split("•").map(&:strip)

    # Convert distance to meters
    distance_km = distance_text[/\d+(\.\d+)?/].to_f
    distance = (distance_km * 1000).to_i
    summary = "#{distance_text} #{type_of_run.downcase}"
    description = description_lines[1...-1].join("\n")

    {
      distance: distance,
      name: name,
      discipline: "Run",
      summary: summary,
      description: description
    }
  end

end
