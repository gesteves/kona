# Selects the content of the races widget from the raw Contentful events and puts it in order. Thus
# the controller and the view do not make those decisions.
class UpcomingRacesPresenter
  include EventsHelper

  # @return [Array<OpenStruct>] The races for the list, the soonest first. An empty array removes
  #   the widget.
  attr_reader :races
  # @return [OpenStruct, nil] The featured event, which gets a large card.
  attr_reader :featured
  # @return [EventWeatherPresenter, nil] The weather of the race day of the featured event.
  attr_reader :event_weather
  # @return [OpenStruct, nil] The featured event when it is the race of today, which gets its own
  #   section.
  attr_reader :todays_race
  # @return [String] The IANA timezone that gives the meaning of "today" and "soon".
  attr_reader :time_zone

  # @param events [Array<OpenStruct>] The raw Contentful events.
  # @param time_zone [String] An IANA timezone id.
  # @param weather_for [#call] Gives the EventWeatherPresenter of an event, or nil. The caller
  #   gives it, thus this class makes no upstream request of its own and a spec needs no stub.
  def initialize(events:, time_zone:, weather_for: RaceDayWeather.method(:for))
    @time_zone = time_zone
    @races = upcoming_races(events, time_zone)
    return if @races.blank?

    @featured = @races.first if featured?(@races.first, @races, time_zone)
    @event_weather = weather_for.call(@featured) if @featured

    @todays_race = @featured if @featured && today?(@featured, time_zone)

    # A featured event that is not today gets the large card only when there is race-day weather for
    # it. The code makes the featured window in the timezone of the owner, and the weather-fetch
    # window in the timezone of the event. Thus the two can be different at the 10-day limit, and a
    # featured card could have an empty weather block. The race of today keeps its section in each
    # condition.
    if @featured && !@todays_race && @event_weather&.forecast.blank?
      @featured = nil
      @event_weather = nil
      @races = @races.take(3)
    end
  end

  # @return [Array<OpenStruct>, nil] The races in the list on a race day, but not the race of today.
  #   It is nil on a day that is not a race day.
  def other_races
    @races.drop(1) if @todays_race
  end

  # Tells if an event in the list is the featured event.
  def featured_event?(event)
    event.sys&.id == featured&.sys&.id
  end

  # @return [String] The layout of the main section, on a day that is not a race day.
  def variant
    event_collection_variant(races.size, featured: featured.present?)
  end

  # @return [String] The layout of the race-day section. That section does not include the race of
  #   today, and it has no featured event.
  def other_races_variant
    event_collection_variant(other_races.size, featured: false)
  end
end
