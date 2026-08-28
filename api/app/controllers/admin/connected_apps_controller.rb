module Admin
  # Lists the external apps whose credentials this app holds, and lets the owner connect one or
  # disconnect one. The page is a list, thus a new app needs only a new presenter at the end.
  class ConnectedAppsController < BaseController
    # GET /connected-apps
    def show
      @apps = [ bluesky_app, mastodon_app, threads_app, whoop_app ]
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
        description: card_description(
          connected: service.connected?,
          account: ("@#{service.handle}" if service.handle.present?),
          summary: "Publishes the blog to the AT Protocol as standard.site records."
        ),
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
        description: card_description(
          connected: service.connected?,
          account: service.handle,
          summary: "Connects a Mastodon account."
        ),
        # The registration and the token are the connection, and each one comes from the round
        # trip. Thus there is no deploy configuration and no :unconfigured state.
        configured: true,
        connected: service.connected?,
        connect_path: mastodon_connection_path,
        disconnect_path: mastodon_connection_path
      )
    end

    def threads_app
      service = Threads.new

      ConnectedAppPresenter.new(
        name: "Threads",
        description: card_description(
          connected: service.connected?,
          account: ("@#{service.username}" if service.username.present?),
          summary: "Connects a Threads account."
        ),
        configured: service.valid_credentials?,
        connected: service.connected?,
        connect_path: threads_authorize_path,
        disconnect_path: threads_connection_path,
        error: (threads_error_message(service.refresh_error) if service.connected?)
      )
    end

    # ⚠️ A Threads token that expires is dead for all time, and only a new authorization corrects
    # that. Thus a refused refresh must reach the owner while the token is still good.
    # @param error [Hash, nil] ThreadsCredentials refresh_error.
    # @return [String, nil] A sentence for the card, or nil when the last refresh was successful.
    def threads_error_message(error)
      return if error.blank?

      failed_at = Time.zone.parse(error[:at].to_s)
      when_it_failed = failed_at ? " on #{failed_at.strftime('%B %-e, %Y at %-I:%M %p %Z')}" : ""

      "Threads refused the last token refresh (HTTP #{error[:code]})#{when_it_failed}. "         "Reconnect before the token expires: an expired Threads token cannot be renewed."
    end

    def whoop_app
      service = Whoop.new
      connected = service.connected?

      ConnectedAppPresenter.new(
        name: "Whoop",
        description: card_description(
          connected: connected,
          account: service.account_email,
          summary: "Syncs strain, sleep, and recovery to Intervals.icu, and powers the Whoop widget."
        ),
        configured: service.valid_credentials?,
        connected: connected,
        connect_path: "/whoop/auth",
        disconnect_path: whoop_connection_path,
        error: (whoop_error_message(service.refresh_error) if connected)
      )
    end

    # The one line of a card. A connected app names its account, thus the page says which account
    # it holds and not what the integration does.
    #
    # ⚠️ Each `account` here comes from Redis, and no card makes a request to name its account. The
    # page renders on each load of the admin, thus a fetch would put an upstream failure in the path
    # of the navigation.
    # @param connected [Boolean] True if an account is connected now.
    # @param account [String, nil] The name of that account, in the form of its own service.
    # @param summary [String] The line to show when nothing is connected: what the integration does.
    # @return [String]
    def card_description(connected:, account:, summary:)
      return summary unless connected

      account.present? ? "Connected as #{account}." : "Connected."
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
