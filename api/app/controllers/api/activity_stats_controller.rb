module Api
  # Serves the activity-stats markup that the static site embeds via its live-update
  # Stimulus controller.
  class ActivityStatsController < BaseController
    def show
      cache_widget(ttl: 5.minutes)

      @stats = Intervals.new.stats
      return render_empty if @stats.nil?

      render :show
    end
  end
end
