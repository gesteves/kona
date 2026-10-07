module Api
  # Takes a cycling FTP and sends it to the Ride sport settings of Intervals.icu and to the profile
  # of the athlete on Strava. Two jobs do the writes, thus a failure at one destination does not
  # stop the other.
  #
  # The parameter: `ftp`, in watts, which is necessary.
  class FtpController < BaseController
    # The API_TOKEN bearer check comes from BaseController.
    skip_forgery_protection

    def create
      return render json: { error: "Missing FTP" }, status: :unprocessable_content if params[:ftp].blank?

      watts = Ftp.parse(params[:ftp])
      return render json: { error: "Invalid FTP" }, status: :unprocessable_content if watts.nil?

      Ftp.save(watts)
      head :no_content
    end
  end
end
