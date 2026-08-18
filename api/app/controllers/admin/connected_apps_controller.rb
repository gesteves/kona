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
      connected = service.connected?

      ConnectedAppPresenter.new(
        name: "Whoop",
        description: "Syncs strain, sleep, and recovery to Intervals.icu, and powers the Whoop widget.",
        configured: service.valid_credentials?,
        connected: connected,
        connect_path: "/whoop/auth",
        disconnect_path: whoop_connection_path,
        error: (whoop_error_message(service.refresh_error) if connected)
      )
    end

    # Whoop leaves its tokens in Redis after rejecting them, so `connected?` alone can't tell a
    # working integration from a dead one — WhoopTokenRefreshJob would go on failing every six
    # hours behind a green badge.
    # @param error [Hash, nil] Whoop#refresh_error.
    # @return [String, nil] A sentence for the card, or nil when the last refresh succeeded.
    def whoop_error_message(error)
      return if error.blank?

      failed_at = Time.zone.parse(error[:at].to_s)
      when_it_failed = failed_at ? " on #{failed_at.strftime('%B %-e, %Y at %-I:%M %p %Z')}" : ""

      "Whoop rejected the last token refresh (HTTP #{error[:code]})#{when_it_failed}. " \
        "The widget and the Intervals.icu sync stay broken until you reconnect."
    end
  end
end
