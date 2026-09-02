module Widgets
  # Renders the Whoop stats markup — the sleep, the recovery, and the strain — for the static
  # site.
  class WhoopController < BaseController
    def show
      cache_widget(ttl: 5.minutes)

      # `safely` separates each upstream call. Thus a timeout or a raise gives "no data", and the
      # widget goes away or omits one section. It does not give a 500. Widgets::WeatherController
      # does the same.
      time_zone = time_zone_of(Location.new)
      stats = safely("Whoop") { Whoop.new.stats }
      return render_empty if stats.nil?

      workouts = planned_workouts(time_zone)
      @whoop = WhoopPresenter.new(stats: stats, workouts: workouts, time_zone: time_zone)
      render :show
    end
  end
end
