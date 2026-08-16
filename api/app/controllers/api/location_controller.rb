module Api
  # Sets the current location used by the weather/Whoop widgets. A bearer-token-secured POST writes
  # the shared "location:current" Redis key (read by this app's Location service); this replaced the
  # old build-hook ingress. It also enqueues a LocationSyncJob to propagate the location to
  # Intervals.icu (athlete profile + weather config) in the background.
  #
  # The write itself lives in Location.store, shared with the admin's Location page so the two
  # can't drift. This endpoint keeps its own error messages: they're read by external callers.
  class LocationController < BaseController
    # The API_TOKEN bearer check is inherited from BaseController; only forgery protection
    # (this is a POST) needs handling here.
    skip_forgery_protection

    def create
      if params[:latitude].blank? || params[:longitude].blank?
        return render json: { error: "Missing coordinates" }, status: :unprocessable_content
      end

      coordinates = Location.parse(params[:latitude], params[:longitude])
      if coordinates.nil?
        return render json: { error: "Invalid coordinates" }, status: :unprocessable_content
      end

      Location.store(*coordinates)
      head :no_content
    end
  end
end
