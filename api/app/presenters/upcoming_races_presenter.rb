# Selects and arranges the races widget's content from the raw Contentful events, keeping those
# decisions out of the controller and view.
class UpcomingRacesPresenter
  include EventsHelper

  # @return [Array<OpenStruct>] The races to list, soonest first. Empty collapses the widget.
  attr_reader :races
  # @return [OpenStruct, nil] The featured event, which gets an expanded card.
  attr_reader :featured
  # @return [EventWeatherPresenter, nil] The featured event's race-day weather.
  attr_reader :event_weather
  # @return [OpenStruct, nil] The featured event when it's today's race, which gets its own
  #   section.
  attr_reader :todays_race
  # @return [String] The IANA timezone anchoring "today" and "soon".
  attr_reader :time_zone

  # @param events [Array<OpenStruct>] The raw Contentful events.
  # @param time_zone [String] An IANA timezone id.
  def initialize(events:, time_zone:)
    @time_zone = time_zone
    @races = upcoming_races(events, time_zone)
    return if @races.blank?

    @featured = @races.first if featured?(@races.first, @races, time_zone)
    @event_weather = RaceDayWeather.new(@featured).presenter if @featured

    @todays_race = @featured if @featured && today?(@featured, time_zone)

    # A not-today featured event only earns the expanded card when there's race-day weather to
    # put in it. The featured window is computed in the owner's timezone and the weather-fetch
    # window in the event's own, so they can disagree at the 10-day boundary and leave a
    # featured card with an empty weather block. Today's race keeps its section regardless.
    if @featured && !@todays_race && @event_weather&.forecast.blank?
      @featured = nil
      @event_weather = nil
      @races = @races.take(3)
    end
  end

  # @return [Array<OpenStruct>, nil] The races listed on race day, excluding today's, or nil
  #   off race day.
  def other_races
    @races.drop(1) if @todays_race
  end

  # Whether an event in the list is the featured one.
  def featured_event?(event)
    event.sys&.id == featured&.sys&.id
  end

  # @return [String] The layout variant for the main section, off race day.
  def variant
    event_collection_variant(races.size, featured: featured.present?)
  end

  # @return [String] The layout variant for the race-day section, which excludes today's race
  #   and is never featured.
  def other_races_variant
    event_collection_variant(other_races.size, featured: false)
  end
end
