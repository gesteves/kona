# Sets the current location used for timezone (and, later, weather/elevation) lookups.
# Replaces the old Netlify build-hook ingress: a bearer-token-secured POST writes the
# shared "location:current" Redis key read by both this app and the web app.
class LocationController < ActionController::Base
  skip_forgery_protection
  before_action :authenticate_token!

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

  private

  def authenticate_token!
    expected = ENV["LOCATION_API_TOKEN"].to_s
    provided = request.authorization.to_s.split(" ", 2).last.to_s

    return if expected.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected)

    head :unauthorized
  end
end
