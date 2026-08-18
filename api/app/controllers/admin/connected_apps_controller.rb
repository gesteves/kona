module Admin
  # Lists the external apps this app holds credentials for, and lets the owner attach or detach
  # them. Whoop is the only one today; the page is a list so adding a second is a matter of
  # appending a presenter.
  class ConnectedAppsController < BaseController
    # GET /connected-apps
    def show
      @apps = [ bluesky_app, whoop_app ]
    end

    # DELETE /connected-apps/whoop
    def whoop
      Whoop.new.disconnect!
      redirect_to connected_apps_path, status: :see_other, notice: "Whoop disconnected."
    end

    private

    def bluesky_app
      service = StandardSite.new

      ConnectedAppPresenter.new(
        name: "Bluesky",
        description: "Publishes the blog to the AT Protocol as standard.site records.",
        # No deployment-config step to get wrong: the credentials are the connection, so this
        # never has an :unconfigured state.
        configured: true,
        connected: service.connected?,
        connect_path: bluesky_connection_path,
        disconnect_path: bluesky_connection_path
      )
    end

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
