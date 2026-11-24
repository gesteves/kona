module Widgets
  # The "Upcoming Races" section of the home page. The static build renders it, and this fragment
  # renders it again at request time. Thus the featured event, the count of three or four, and
  # each "Today" label stay correct. The race-day weather of a featured event renders here. The
  # cache holds it for one hour.
  class EventsController < BaseController
    def upcoming
      # The stale-while-revalidate value at the edge stays at the default of one hour. Each "Today"
      # label and the choice of the featured event change with the day, thus an old copy must not
      # stay much longer than the fresh window.
      render_widget(:upcoming, ttl: 1.hour) do
        # The timezone in the configuration of the owner gives the meaning of "today" and "soon" for
        # the race list. This widget does not follow the current location of the owner.
        @races = UpcomingRacesPresenter.new(events: Events.new.all, time_zone: TimeZoneResolver.default,
                                            weather_for: RaceDayWeather.method(:for))
        @races.races
      end
    end
  end
end
