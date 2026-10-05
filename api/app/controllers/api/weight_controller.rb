module Api
  # Takes a body weight and sends it to the wellness record of Intervals.icu and to the profile of
  # the athlete on Strava. Two jobs do the writes, thus a failure at one destination does not stop
  # the other.
  #
  # The parameters: `weight`, which is necessary; `unit`, which is "kg" or "lb" and has the default
  # "kg"; and `date`, an ISO 8601 day with the default of today in the time zone of the location.
  class WeightController < BaseController
    # The API_TOKEN bearer check comes from BaseController.
    skip_forgery_protection

    def create
      return render json: { error: "Missing weight" }, status: :unprocessable_content if params[:weight].blank?

      kg = Weight.parse(params[:weight], params[:unit])
      return render json: { error: "Invalid weight" }, status: :unprocessable_content if kg.nil?

      date = Weight.parse_date(params[:date])
      return render json: { error: "Invalid date" }, status: :unprocessable_content if date.nil?

      Weight.save(kg, date)
      head :no_content
    end
  end
end
