module Widgets
  # The "Upcoming Races" section of the home page. The server renders it at request time, and the
  # static build does not contain it. Thus the featured event, the count of three or four, and each
  # "Today" label stay correct. When there is a featured event, its race-day weather renders here,
  # and it replaces the separate weather widget of the past. The cache holds it for one hour.
  class EventsController < BaseController
    def upcoming
      # The stale-while-revalidate value at the edge stays at the default of one hour. Each "Today"
      # label and the choice of the featured event change with the day, thus an old copy must not
      # stay much longer than the fresh window.
      render_widget(:upcoming, ttl: 1.hour) do
        # The timezone in the configuration of the owner gives the meaning of "today" and "soon" for
        # the race list. This widget does not follow the current location of the owner. The presenter
        # selects the races and decides the featured one, and the view reads each value through
        # @races.
        @races = UpcomingRacesPresenter.new(events: Events.new.all, time_zone: TimeZoneResolver.default)
        @races.races
      end
    end
  end
end
