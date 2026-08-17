module Admin
  # Lists the external apps this app holds credentials for, and lets the owner attach or detach
  # them. Whoop is the only one today; the page is a list so adding a second is a matter of
  # appending a presenter.
  class ConnectedAppsController < BaseController
    # GET /connected-apps
    def show
      @apps = [ whoop_app ]
    end

    # DELETE /connected-apps/whoop
    def whoop
      Whoop.new.disconnect!
      redirect_to connected_apps_path, status: :see_other, notice: "Whoop disconnected."
    end

    private

    def whoop_app
      service = Whoop.new

      ConnectedAppPresenter.new(
        name: "Whoop",
        description: "Syncs strain, sleep, and recovery to Intervals.icu, and powers the Whoop widget.",
        configured: service.valid_credentials?,
        connected: service.connected?,
        connect_path: "/whoop/auth",
        disconnect_path: whoop_connection_path
      )
    end
  end
end
