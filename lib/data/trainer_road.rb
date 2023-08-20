require 'httparty'
require 'active_support/all'
require 'icalendar'
require 'nokogiri'

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
      workout_summary = parse_summary(event.summary)
      alt_desc = event.custom_properties["x_alt_desc"]&.first
      workout_details = alt_desc ? parse_html_description(alt_desc) : parse_description(event.description)

      workout = {
        discipline: determine_discipline(event.summary)
      }

      workout.merge(workout_summary).merge(workout_details)
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


  def parse_description(desc)
    tss = desc[/TSS (\d+(\.\d+)?)/, 1]
    if_val = desc[/IF (\d+(\.\d+)?)/, 1]
    kj = desc[/kJ\(Cal\) (\d+(\.\d+)?)/, 1]
    goals = desc[/Goals: (.*?)\./, 1]
    description = desc[/Description: (.*?)\. Goals:/, 1]

    {
      tss: tss ? tss.to_f : nil,
      if: if_val ? if_val.to_f : nil,
      kj: kj ? kj.to_i : nil,
      goals: goals || '',
      description: description || ''
    }
  end

  def parse_html_description(html_content)
    doc = Nokogiri::HTML(html_content)

    stats = doc.at('h4').text if doc.at('h4')
    tss = stats[/TSS (\d+(\.\d+)?)/, 1]
    if_val = stats[/IF (\d+(\.\d+)?)/, 1]
    kj = stats[/kJ\(Cal\) (\d+(\.\d+)?)/, 1]

    description_header = doc.at('h4[text()="Power Based Description"]') || doc.at('h4[text()="Description"]')
    description_text = collect_text(description_header) if description_header

    goals_header = doc.at('h4[text()="Goals"]')
    goals_text = collect_text(goals_header) if goals_header

    {
      tss: tss ? tss.to_f : nil,
      if: if_val ? if_val.to_f : nil,
      kj: kj ? kj.to_i : nil,
      goals: goals_text ? goals_text.join(' ') : '',
      description: description_text ? description_text.join(' ') : ''
    }
  end

  def collect_text(node)
    texts = []
    current_node = node.next_element

    while current_node && current_node.name != 'h4'
      texts << current_node.text.strip
      current_node = current_node.next_element
    end

    texts
  end

  def determine_discipline(name)
    return "Run" if name.include?("Run")
    return "Swim" if name.include?("Swim")
    "Bike"
  end
end
