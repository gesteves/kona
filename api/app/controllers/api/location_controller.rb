module Api
  # Sets the current location that the weather widget and the Whoop widget use. A POST with a
  # bearer token writes the "location:current" Redis key, and a LocationSyncJob then sends the
  # location to Intervals.icu.
  #
  # Location.save does the write, and the Location page of the admin uses the same method. Thus
  # the two always agree. This endpoint keeps its own error messages, because an external caller
  # reads them.
  class LocationController < BaseController
    def create
      if params[:latitude].blank? || params[:longitude].blank?
        return render json: { error: "Missing coordinates" }, status: :unprocessable_content
      end

      coordinates = Location.save(params[:latitude], params[:longitude])
      if coordinates.nil?
        return render json: { error: "Invalid coordinates" }, status: :unprocessable_content
      end

      head :no_content
    end
  end
end
