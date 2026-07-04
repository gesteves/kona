# Selects and arranges the races widget's content from the raw Contentful events: the
# trimmed upcoming list, the featured event (with its race-day weather), today's race, and
# the section layout variants. Keeps those decisions out of the controller and view — the
# view reads everything through this presenter.
class UpcomingRacesPresenter
  include EventsHelper

  # The races to list, soonest first (see EventsHelper#upcoming_races; empty when nothing
  # is upcoming, which collapses the widget).
  attr_reader :races
  # The featured event (expanded card + race-day weather), or nil.
  attr_reader :featured
  # The featured event's race-day weather, or nil.
  # @return [EventWeatherPresenter, nil]
  attr_reader :event_weather
  # The featured event when it's today's race (it gets its own section), or nil.
  attr_reader :todays_race
  # The IANA timezone anchoring "today"/"soon".
  attr_reader :time_zone

  # @param events [Array<OpenStruct>] The raw Contentful events.
  # @param time_zone [String] An IANA timezone id.
  def initialize(events:, time_zone:)
    @time_zone = time_zone
    @races = upcoming_races(events, time_zone)
    return if @races.blank?

    @featured = @races.first if featured?(@races.first, @races, time_zone)
    @event_weather = RaceDayWeather.new(@featured).presenter if @featured

    # On race day the featured event is today's race; give it its own section.
    @todays_race = @featured if @featured && today?(@featured, time_zone)

    # An upcoming (not-today) featured event only earns the expanded treatment when we actually
    # have race-day weather to show. The featured window (close?, in the owner's timezone) and
    # the weather-fetch window (days_until, computed in the event's own geocoded timezone) can
    # disagree at the 10-day boundary, which would otherwise leave a featured card carrying an
    # empty "Race Day Weather" block for an event that's effectively more than 10 days out. When
    # the weather's missing, demote it to a regular upcoming race (and trim back to the
    # non-featured count). Today's race keeps its section regardless — it's race day.
    if @featured && !@todays_race && @event_weather&.forecast.blank?
      @featured = nil
      @event_weather = nil
      @races = @races.take(3)
    end
  end

  # The races listed under "Upcoming Races" on race day (everything but today's race), or
  # nil off race day.
  # @return [Array<OpenStruct>, nil]
  def other_races
    @races.drop(1) if @todays_race
  end

  # Whether an event in the list is the featured one (expanded card + inline weather).
  def featured_event?(event)
    event.sys&.id == featured&.sys&.id
  end

  # The layout variant for the main "Upcoming Races" section (off race day).
  def variant
    event_collection_variant(races.size, featured: featured.present?)
  end

  # The layout variant for the race-day "Upcoming Races" section (today's race excluded,
  # never featured).
  def other_races_variant
    event_collection_variant(other_races.size, featured: false)
  end
end
