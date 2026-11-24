module Widgets
  # Renders the Whoop stats markup for the static site: the sleep, the recovery, and the strain.
  class WhoopController < BaseController
    def show
      cache_widget(ttl: 5.minutes)

      # `safely` separates each upstream call, as in Widgets::WeatherController. Thus a timeout or a
      # raise gives "no data", and not a 500.
      time_zone = time_zone_of(Location.new)
      stats = safely("Whoop") { Whoop.new.stats }
      return render_empty if stats.nil?

      workouts = planned_workouts(time_zone)
      @whoop = WhoopPresenter.new(stats: stats, workouts: workouts, time_zone: time_zone)
      render :show
    end
  end
end
