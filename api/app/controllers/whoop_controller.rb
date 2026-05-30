# Renders the Whoop stats markup (sleep, recovery, strain) embedded into the static
# site. Inherits from ActionController::Base directly (not ApplicationController) to
# skip the modern-browser gate, since this is a public, cross-origin endpoint.
class WhoopController < ActionController::Base
  def show
    @time_zone = resolve_time_zone
    @whoop = Whoop.new.stats
    expires_in 5.minutes, public: true, stale_while_revalidate: 1.hour

    if @whoop.nil?
      # The live-update controller no-ops on an empty response, leaving the existing markup in place.
      render plain: "", layout: false
    else
      @workouts = TrainerRoad.new(@time_zone).workouts || []
      render :show, layout: false
    end
  end

  private

  # Resolves the current timezone from the owner's location, falling back to TIME_ZONE
  # (or America/Denver) when location or geocoding is unavailable.
  # @return [String] An IANA timezone ID.
  def resolve_time_zone
    location = Location.new
    time_zone = GoogleMaps.new(location.latitude, location.longitude).time_zone_id if location.latitude.present?
    time_zone || ENV.fetch("TIME_ZONE", "America/Denver")
  end
end
