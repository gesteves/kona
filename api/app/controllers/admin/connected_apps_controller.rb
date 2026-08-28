module Admin
  # Lists the external apps whose credentials this app holds, and lets the owner connect one or
  # disconnect one. The page is a list, thus a new app needs only a new presenter at the end.
  class ConnectedAppsController < BaseController
    # GET /connected-apps
    def show
      @apps = [ bluesky_app, mastodon_app, whoop_app ]
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
        # There is no deploy configuration to make incorrect: the credentials are the connection,
        # thus this app never has the :unconfigured state.
        configured: true,
        connected: service.connected?,
        connect_path: bluesky_connection_path,
        disconnect_path: bluesky_connection_path
      )
    end

    def mastodon_app
      service = Mastodon.new

      ConnectedAppPresenter.new(
        name: "Mastodon",
        description: mastodon_description(service.handle),
        # The registration and the token are the connection, and each one comes from the round
        # trip. Thus there is no deploy configuration and no :unconfigured state.
        configured: true,
        connected: service.connected?,
        connect_path: mastodon_connection_path,
        disconnect_path: mastodon_connection_path
      )
    end

    # @param handle [String, nil] The "@user@instance" name of the connected account.
    # @return [String] One line for the card. The account is there when there is one, because the
    #   instance is the part of this connection that the owner selects.
    def mastodon_description(handle)
      return "Connects a Mastodon account. Nothing posts to it yet." if handle.blank?

      "Connected as #{handle}. Nothing posts to it yet."
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

    # Whoop keeps its tokens in Redis after it refuses them, thus `connected?` alone cannot show the
    # difference between an integration that works and one that does not. WhoopTokenRefreshJob would
    # continue to fail each six hours below a green badge.
    # @param error [Hash, nil] Whoop#refresh_error.
    # @return [String, nil] A sentence for the card, or nil when the last refresh was successful.
    def whoop_error_message(error)
      return if error.blank?

      failed_at = Time.zone.parse(error[:at].to_s)
      when_it_failed = failed_at ? " on #{failed_at.strftime('%B %-e, %Y at %-I:%M %p %Z')}" : ""

      "Whoop rejected the last token refresh (HTTP #{error[:code]})#{when_it_failed}. " \
        "The widget and the Intervals.icu sync stay broken until you reconnect."
    end
  end
end
