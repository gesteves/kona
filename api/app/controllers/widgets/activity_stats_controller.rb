module Widgets
  # Gives the activity-stats markup. The live-update Stimulus controller of the static site puts it
  # in the page.
  class ActivityStatsController < BaseController
    def show
      # `safely` separates the upstream call: a timeout gives "no data" and not a 500.
      render_widget(:show, ttl: 5.minutes) { @stats = safely("Intervals.icu") { Intervals.new.stats } }
    end
  end
end
