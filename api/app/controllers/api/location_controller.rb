module Api
  # Sets the current location used by the weather/Whoop widgets. A bearer-token-secured POST writes
  # the shared "location:current" Redis key (read by this app's Location service); this replaced the
  # old Netlify build-hook ingress.
  class LocationController < BaseController
    # The API_TOKEN bearer check is inherited from BaseController; only forgery protection
    # (this is a POST) needs handling here.
    skip_forgery_protection

    def create
      if params[:latitude].blank? || params[:longitude].blank?
        return render json: { error: "Missing coordinates" }, status: :unprocessable_content
      end

      # Float() (not to_f) so non-numeric input is rejected instead of silently becoming 0.0
      # (the Gulf of Guinea) and corrupting the stored location.
      latitude = Float(params[:latitude], exception: false)
      longitude = Float(params[:longitude], exception: false)

      unless Location.valid_coordinates?(latitude, longitude)
        return render json: { error: "Invalid coordinates" }, status: :unprocessable_content
      end

      $redis.set(Location::LOCATION_CACHE_KEY, "#{latitude},#{longitude}")
      head :no_content
    end
  end
end
