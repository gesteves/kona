module Admin
  # Connects the TrainerRoad calendar feed, with the iCalendar URL of the account.
  #
  # There is no OAuth round trip, thus a connection is a form post and not a redirect, as with
  # Bluesky. That is why all three actions are here and not on ConnectedAppsController.
  class TrainerRoadController < BaseController
    # GET /connected-apps/trainerroad
    def show
      @stored = TrainerRoadCredentials.stored?
    end

    # POST /connected-apps/trainerroad
    #
    # ⚠️ The code gets the feed before it stores the URL. A URL with a typing error, that the code
    # stores with no check, makes the rest-day check and the planned-workout line fail with no
    # message. This page exists to show that failure.
    def create
      url = params[:calendar_url].to_s.strip.presence

      if TrainerRoad.new(calendar_url: url).connect!
        redirect_to connected_apps_path, status: :see_other, notice: t("admin.trainer_road.flash.connected")
      else
        @stored = TrainerRoadCredentials.stored?
        flash.now[:alert] = t("admin.trainer_road.flash.refused")
        render :show, status: :unprocessable_content
      end
    end

    # DELETE /connected-apps/trainerroad
    def destroy
      TrainerRoad.new.disconnect!
      redirect_to connected_apps_path, status: :see_other, notice: t("admin.trainer_road.flash.disconnected")
    end
  end
end
