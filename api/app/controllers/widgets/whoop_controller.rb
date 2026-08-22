module Widgets
  # Renders the Whoop stats markup — the sleep, the recovery, and the strain — for the static
  # site.
  class WhoopController < BaseController
    def show
      cache_widget(ttl: 5.minutes)

      # `safely` separates each upstream call. Thus a timeout or a raise gives "no data", and the
      # widget goes away or omits one section. It does not give a 500. Widgets::WeatherController
      # does the same.
      location = Location.new
      time_zone = safely("GoogleMaps") { TimeZoneResolver.call(location.latitude, location.longitude) } ||
                  TimeZoneResolver.default
      stats = safely("Whoop") { Whoop.new.stats }
      return render_empty if stats.nil?

      workouts = safely("TrainerRoad", []) { TrainerRoad.new(time_zone).workouts } || []
      @whoop = WhoopPresenter.new(stats: stats, workouts: workouts, time_zone: time_zone)
      render :show
    end
  end
end
