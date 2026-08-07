module Widgets
  # Renders the Whoop stats markup (sleep, recovery, strain) embedded into the static site.
  class WhoopController < BaseController
    def show
      cache_widget(ttl: 5.minutes)

      # Each upstream is isolated (safely) so a timeout or raise degrades to "no data" — the
      # widget collapses or omits a section instead of 500ing. Matches Widgets::WeatherController.
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
