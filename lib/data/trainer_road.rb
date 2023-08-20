require 'httparty'
require 'active_support/all'
require 'icalendar'

class TrainerRoad
  CALENDAR_URL = ENV['TRAINERROAD_CALENDAR_URL']

  def initialize
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
  end

  def workouts
    cache_key = "trainerroad:workouts:#{CALENDAR_URL.parameterize}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    response = HTTParty.get(CALENDAR_URL)
    return [] unless response.success?

    calendars = Icalendar::Calendar.parse(response.body)
    calendar = calendars.first
    today = Date.today

    todays_events = calendar.events.select do |event|
      event.dtstart.to_date == today
    end

    workouts = todays_events.map do |event|
      workout = parse_summary(event.summary)
      workout[:discipline] = determine_discipline(workout[:name])
      workout
    end

    @redis.setex(cache_key, 1.hour, workouts.to_json)

    workouts
  end

  def save_data
    data = {
      workouts: workouts
    }
    File.open('data/trainerroad.json', 'w') { |f| f << data.to_json }
  end

  private

  def parse_summary(summary)
    match_data = /(\d+:\d+) - (.+)/.match(summary)

    {
      duration: match_data[1],
      name: match_data[2]
    }
  end

  def determine_discipline(name)
    return "Run" if name.include?("Run")
    return "Swim" if name.include?("Swim")
    "Bike"
  end
end
