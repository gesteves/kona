# The selection and the markup of the upcoming-races section, at build time.
#
# ⚠️ These are a copy of `EventsHelper` and `UpcomingRacesPresenter` in the api, which render the
# same section at request time and put it in place of this one. The two must agree on the races in
# the list and on their order. If they do not, the change is visible in the section. This copy is
# smaller, on purpose: the api also makes the next race a featured race with a race-day weather
# block, and it gives the race of today its own section. The build cannot know either of those.
# Refer to the root CLAUDE.md.
module EventHelpers
  # The number of races in the section when there is no featured race. It is the same number that
  # the api uses in that condition.
  UPCOMING_RACES_COUNT = 3

  # The races for the list: the confirmed events of today or later, the soonest first.
  # @param count [Integer] The number to return.
  # @return [Array] The events, the soonest first. An empty array removes the section.
  def upcoming_races(count: UPCOMING_RACES_COUNT)
    events = Array(data.events)
    return [] if events.blank?

    today = event_today
    events
      .filter_map do |event|
        date = event.going ? parse_event_date(event) : nil
        [ date, event ] if date && date >= today
      end
      .sort_by(&:first)
      .map(&:last)
      .first(count)
  end

  # @param count [Integer] The number of races in the section.
  # @return [String] The layout, the same as the `event_collection_variant` of the api when there
  #   is no featured race.
  def event_collection_variant(count)
    case count
    when 1 then "single"
    when 2 then "halves"
    else "thirds"
    end
  end

  # @param event [Object] The event.
  # @return [String] The icon and the <time> span for an upcoming race, the same as the
  #   `event_timestamp_tag` of the api. Only a confirmed event comes here, thus the icon is always
  #   a calendar check.
  def event_timestamp_tag(event)
    date = parse_event_date(event)
    return "".html_safe if date.nil?

    timestamp = content_tag(:time, date.strftime("%B %-e, %Y"), datetime: date.iso8601)
    content_tag :span, "#{icon_svg('classic', 'light', 'calendar-check')} #{timestamp}".html_safe
  end

  # The JSON-LD `SportsEvent` list for the races in the section. Thus a machine can read the same
  # events that the page shows.
  #
  # ⚠️ The build writes this only for the events that it counts as upcoming. There is no build on a
  # schedule, thus between two publishes this can name a race that already occurred. A `startDate`
  # in the past makes the entry incorrect for an event rich result, but the entry is not wrong.
  # That failure is acceptable here.
  # @param events [Array] The events, from #upcoming_races.
  # @return [String, nil] The JSON-LD, or nil if there is nothing to list.
  def events_schema(events)
    entries = Array(events).filter_map { |event| event_schema(event) }
    return if entries.empty?
    entries.to_json
  end

  private

  # @return [Date] Today in the timezone of the site, thus "upcoming" changes at the same moment
  #   for each reader. The publish dates use the same timezone.
  def event_today
    zone = site_time_zone
    zone.present? ? Time.now.in_time_zone(zone).to_date : Date.today
  end

  # @param event [Object] The event.
  # @return [Hash, nil] One `SportsEvent` node, or nil if the code cannot parse the date.
  def event_schema(event)
    date = parse_event_date(event)
    return if date.nil?

    schema = {
      "@context": "https://schema.org",
      "@type": "SportsEvent",
      "name": sanitize(event.title),
      "startDate": date.iso8601,
      # Each event is a race on one day, and Google counts an absent eventStatus as unknown.
      "eventStatus": "https://schema.org/EventScheduled",
      "eventAttendanceMode": "https://schema.org/OfflineEventAttendanceMode"
    }
    schema[:description] = sanitize(event.summary) if event.summary.present?
    if event.location.present?
      # `address` is text, and not a PostalAddress. Contentful holds the location as one line of
      # free text ("Richland, Washington") with no parts to divide it into. Google needs the field
      # for an event rich result and accepts Text, thus this is all that the build can give.
      place = sanitize(event.location)
      schema[:location] = { "@type": "Place", "name": place, "address": place }
    end
    schema[:url] = event.url if event.url.present?
    # The author is a competitor, and not the organizer. `performer` is the only correct statement
    # that the build can make about the relation of this site to the race.
    schema[:performer] = { "@id": schema_entity_id("person", path: "/about") }
    schema
  end

  # ⚠️ Contentful can hold an event with no date, and this code runs on the render path of the home
  # page. A plain parse would stop the full page because of one bad entry, and not remove one
  # card.
  # @param event [Object] The event.
  # @return [Date, nil]
  def parse_event_date(event)
    date = event&.date
    return if date.blank?
    Time.parse(date).to_date
  rescue ArgumentError, TypeError
    nil
  end
end
