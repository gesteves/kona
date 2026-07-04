module Widgets
  # The home page's "Upcoming Races" section, rendered server-side at request time (instead of
  # baked into the static build) so the featured event, the three-vs-four count, and "Today"
  # labels stay fresh. When an event is featured, its race-day weather renders inline here —
  # replacing the former standalone weather/event widget. Cached for an hour.
  class EventsController < BaseController
    def upcoming
      # Edge SWR kept at a day (vs. the one-hour default): the upcoming-races list changes
      # rarely, so serving a stale copy while revalidating costs nothing.
      render_widget(:upcoming, ttl: 1.hour, edge_stale_while_revalidate: 1.day) do
        # The owner's configured timezone anchors "today"/"soon" for the race list (this
        # widget doesn't track the owner's current location). The selection/featuring
        # decisions live in the presenter; the view reads everything through @races.
        @races = UpcomingRacesPresenter.new(events: Events.new.all, time_zone: TimeZoneResolver.default)
        @races.races
      end
    end
  end
end
