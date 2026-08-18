module Admin
  # Attaches a Bluesky account to the standard.site sync, by handle and app password.
  #
  # Unlike Whoop there's no OAuth round trip, so connecting is a form post rather than a redirect
  # — which is why all three actions live here instead of on ConnectedAppsController.
  class BlueskyController < BaseController
    # GET /connected-apps/bluesky
    def show
      credentials = BlueskyCredentials.fetch
      @handle = credentials.handle
      @stored = credentials.usable?
    end

    # POST /connected-apps/bluesky
    #
    # ⚠️ Validates before storing, by actually opening a PDS session with the submitted pair. A
    # typo'd app password stored blind would leave the sync failing silently on the next publish,
    # which is the exact failure this page exists to surface.
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
