require 'httparty'
require 'active_support/all'
require 'icalendar'

class TrainerRoad
  CALENDAR_URL = ENV['TRAINERROAD_CALENDAR_URL']

  def initialize(timezone = "America/Denver")
    @timezone = timezone
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
  end

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
      event.dtstart.to_datetime.in_time_zone(@timezone).to_date == today
    end

    workouts = todays_events.map do |event|
      parse_workout(event.summary)
    end

    workouts.compact!

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

  def parse_workout(summary)
    match_data = /(\d+:\d+) - (.+)/.match(summary)
    return nil if match_data.blank?

    {
      duration: match_data[1],
      name: match_data[2],
      discipline: determine_discipline(match_data[2])
    }
  end

  def determine_discipline(name)
    return if name.blank?
    return "Run" if name.include?("Run")
    return "Swim" if name.include?("Swim")
    "Bike"
  end
end