module Widgets
  # Renders the Whoop stats markup (sleep, recovery, strain) embedded into the static site.
  class WhoopController < BaseController
    def show
      cache_widget(ttl: 5.minutes)

      location = Location.new
      time_zone = TimeZoneResolver.call(location.latitude, location.longitude)
      stats = Whoop.new.stats
      return render_empty if stats.nil?

      @whoop = WhoopPresenter.new(stats: stats, workouts: TrainerRoad.new(time_zone).workouts, time_zone: time_zone)
      render :show
    end
  end
end
