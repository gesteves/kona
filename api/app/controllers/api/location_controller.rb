module Api
  # Sets the current location that the weather widget and the Whoop widget use. A POST with a bearer
  # token writes the shared "location:current" Redis key, which the Location service of this app
  # reads. This replaced the build-hook input of the past. It also adds a LocationSyncJob to the
  # queue, which sends the location to Intervals.icu, to the profile of the athlete and to the
  # weather configuration, in the background.
  #
  # Location.store does the write, and the Location page of the admin uses the same method. Thus the
  # two always agree. This endpoint keeps its own error messages, because an external caller reads
  # them.
  class LocationController < BaseController
    # The API_TOKEN bearer check comes from BaseController. Only the forgery protection needs code
    # here, because this is a POST.
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
