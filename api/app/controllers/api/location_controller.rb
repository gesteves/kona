module Api
  # Sets the current location used by the weather/Whoop widgets. A bearer-token-secured POST writes
  # the shared "location:current" Redis key (read by this app's Location service); this replaced the
  # old Netlify build-hook ingress.
  class LocationController < BaseController
    include TokenAuthentication

    skip_forgery_protection
    before_action :authenticate_bearer_token!, only: :create

    def create
      if params[:latitude].blank? || params[:longitude].blank?
        return render json: { error: "Missing coordinates" }, status: :unprocessable_content
      end

      latitude = params[:latitude].to_f
      longitude = params[:longitude].to_f

      unless Location.valid_coordinates?(latitude, longitude)
        return render json: { error: "Invalid coordinates" }, status: :unprocessable_content
      end

      $redis.set(Location::LOCATION_CACHE_KEY, "#{latitude},#{longitude}")
      head :no_content
    end
  end
end
