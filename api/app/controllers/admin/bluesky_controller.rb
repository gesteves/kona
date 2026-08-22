module Admin
  # Connects a Bluesky account to the standard.site sync, with a handle and an app password.
  #
  # Whoop is different: there is no OAuth round trip here, thus a connection is a form post and not
  # a redirect. That is why all three actions are here and not on ConnectedAppsController.
  class BlueskyController < BaseController
    # GET /connected-apps/bluesky
    def show
      credentials = BlueskyCredentials.fetch
      @handle = credentials.handle
      @stored = credentials.usable?
    end

    # POST /connected-apps/bluesky
    #
    # ⚠️ The code checks the pair before it stores it, and it opens a true PDS session with that
    # pair. An app password with a typing error, that the code stores with no check, would make the
    # sync fail at the next publish and give no message. This page exists to show that failure.
    def create
      submitted = BlueskyCredentials::Credentials.new(
        handle: params[:handle].to_s.strip.delete_prefix("@").presence,
        app_password: params[:app_password].presence
      )

      if StandardSite.new(credentials: submitted).connect!
        redirect_to connected_apps_path, status: :see_other, notice: "Bluesky connected."
      else
        @stored = BlueskyCredentials.stored?
        @handle = submitted.handle
        flash.now[:alert] = "Those credentials didn't open a Bluesky session. Check the handle and app password."
        render :show, status: :unprocessable_content
      end
    end

    # DELETE /connected-apps/bluesky
    def destroy
      StandardSite.new.disconnect!
      redirect_to connected_apps_path, status: :see_other, notice: "Bluesky disconnected."
    end
  end
end
