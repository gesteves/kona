module Widgets
  # Serves the activity-stats markup that the static site embeds via its live-update
  # Stimulus controller.
  class ActivityStatsController < BaseController
    def show
      render_widget(:show, ttl: 5.minutes) { @stats = Intervals.new.stats }
    end
  end
end
