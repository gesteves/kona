module Widgets
  # Gives the activity-stats markup. The live-update Stimulus controller of the static site puts it
  # in the page.
  class ActivityStatsController < BaseController
    def show
      render_widget(:show, ttl: 5.minutes) { @stats = Intervals.new.stats }
    end
  end
end
