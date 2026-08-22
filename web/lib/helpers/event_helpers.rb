# Build-time selection and markup for the upcoming-races section.
#
# ⚠️ These mirror `EventsHelper` and `UpcomingRacesPresenter` in the api, which render the same
# section at request time and swap it over this one. The two must agree on which races are
# listed and in what order, or the swap visibly reshuffles the section. Deliberately reduced:
# the api also features the next race with a race-day weather block and gives today's race its
# own section, neither of which the build can know. See the root CLAUDE.md.
module EventHelpers
  # How many races the section lists when none is featured — the api's unfeatured take.
  UPCOMING_RACES_COUNT = 3

  # The races to list: confirmed events today or later, soonest first.
  # @param count [Integer] How many to return.
  # @return [Array] The events, soonest first. Empty collapses the section.
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

  # @param count [Integer] How many races the section lists.
  # @return [String] The layout variant, matching the api's `event_collection_variant` for the
  #   unfeatured case.
  def event_collection_variant(count)
    case count
    when 1 then "single"
    when 2 then "halves"
    else "thirds"
    end
  end

  # @param event [Object] The event.
  # @return [String] The icon and <time> span for an upcoming race, matching the api's
  #   `event_timestamp_tag`. Only confirmed events reach here, so the icon is always a
  #   calendar check.
  def event_timestamp_tag(event)
    date = parse_event_date(event)
    return "".html_safe if date.nil?

    timestamp = content_tag(:time, date.strftime("%B %-e, %Y"), datetime: date.iso8601)
    content_tag :span, "#{icon_svg('classic', 'light', 'calendar-check')} #{timestamp}".html_safe
  end

  # The JSON-LD `SportsEvent` list for the races the section lists, so the same events the page
  # shows are machine-readable.
  #
  # ⚠️ Emitted only for events the build believes are upcoming. There is no scheduled rebuild,
  # so between publishes this can name a race that has already happened; a past `startDate`
  # makes the entry ineligible for an event rich result rather than wrong, which is the
  # tolerable failure here.
  # @param events [Array] The events, as returned by #upcoming_races.
  # @return [String, nil] JSON-LD, or nil when there's nothing to list.
  def events_schema(events)
    entries = Array(events).filter_map { |event| event_schema(event) }
    return if entries.empty?
    entries.to_json
  end

  private

  # @return [Date] Today in the site's configured timezone, so "upcoming" flips at the same
  #   instant for every reader — the same anchor the publish dates use.
  def event_today
    zone = site_time_zone
    zone.present? ? Time.now.in_time_zone(zone).to_date : Date.today
  end

  # @param event [Object] The event.
  # @return [Hash, nil] One `SportsEvent` node, or nil without a parseable date.
  def event_schema(event)
    date = parse_event_date(event)
    return if date.nil?

    schema = {
      "@context": "https://schema.org",
      "@type": "SportsEvent",
      "name": sanitize(event.title),
      "startDate": date.iso8601,
      # The events are single-day races, and Google treats a missing eventStatus as unknown.
      "eventStatus": "https://schema.org/EventScheduled",
      "eventAttendanceMode": "https://schema.org/OfflineEventAttendanceMode"
    }
    schema[:description] = sanitize(event.summary) if event.summary.present?
    if event.location.present?
      # `address` as text, not a PostalAddress: Contentful holds the location as one free-text
      # line ("Richland, Washington") with no structured parts to split it into. Google requires
      # the field for an event rich result and accepts Text, so this is the most it can say.
      place = sanitize(event.location)
      schema[:location] = { "@type": "Place", "name": place, "address": place }
    end
    schema[:url] = event.url if event.url.present?
    # The author is a competitor, not the organizer — `performer` is the only honest claim the
    # build can make about this site's relationship to the race.
    schema[:performer] = { "@id": schema_entity_id("person", path: "/about") }
    schema
  end

  # ⚠️ Contentful will hold an event with no date, and this runs on the home page's render path
  # — a bare parse takes the whole page down over one bad entry instead of dropping a card.
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
