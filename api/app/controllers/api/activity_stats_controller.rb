module Api
  # Serves the activity-stats markup that the static site embeds via its live-update
  # Stimulus controller. Inherits from ActionController::Base directly (not
  # ApplicationController) to skip the modern-browser gate — this is a public endpoint
  # fetched programmatically and embedded cross-origin.
  class ActivityStatsController < ActionController::Base
    def show
      @stats = Intervals.new.stats
      expires_in 5.minutes, public: true, stale_while_revalidate: 1.hour

      if @stats.nil?
        # The live-update controller no-ops on an empty response, leaving the existing markup in place.
        render plain: "", layout: false
      else
        render :show, layout: false
      end
    end
  end
end
