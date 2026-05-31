module Api
  # Renders the Whoop stats markup (sleep, recovery, strain) embedded into the static site.
  class WhoopController < BaseController
    def show
      cache_widget(ttl: 5.minutes)

      location = Location.new
      @time_zone = TimeZoneResolver.call(location.latitude, location.longitude)
      @whoop = Whoop.new.stats
      return render_empty if @whoop.nil?

      @workouts = TrainerRoad.new(@time_zone).workouts || []
      render :show
    end
  end
end
