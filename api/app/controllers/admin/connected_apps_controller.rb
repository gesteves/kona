module Admin
  # Lists the external apps whose credentials this app holds, and lets the owner connect one or
  # disconnect one. The page is a list, thus a new app needs only a new presenter at the end.
  class ConnectedAppsController < BaseController
    # GET /connected-apps
    #
    # ⚠️ A card is on the page only when its integration can operate. Whoop and Threads need
    # credentials in the environment, thus without those the page hides the card and does not offer
    # an action that cannot work. Bluesky and Mastodon have no such configuration — their
    # credentials *are* the connection — thus they are always here and the list is never empty.
    def show
      @apps = [ bluesky_app, mastodon_app, threads_app, whoop_app ].compact
    end

    # DELETE /connected-apps/whoop
    def whoop
      Whoop.new.disconnect!
      redirect_to connected_apps_path, status: :see_other, notice: t("admin.connected_apps.flash.whoop_disconnected")
    end

    private

    def bluesky_app
      service = StandardSite.new

      # There is no deploy configuration to make incorrect: the credentials are the connection,
      # thus this card is always on the page.
      ConnectedAppPresenter.new(
        name: t("admin.networks.bluesky"),
        description: card_description(
          connected: service.connected?,
          account: ("@#{service.handle}" if service.handle.present?),
          summary: t("admin.connected_apps.summary.bluesky")
        ),
        connected: service.connected?,
        connect_path: bluesky_connection_path,
        disconnect_path: bluesky_connection_path
      )
    end

    def mastodon_app
      service = Mastodon.new

      # The registration and the token are the connection, and each one comes from the round trip.
      # Thus there is no deploy configuration and this card is always on the page.
      ConnectedAppPresenter.new(
        name: t("admin.networks.mastodon"),
        description: card_description(
          connected: service.connected?,
          account: service.handle,
          summary: t("admin.connected_apps.summary.mastodon")
        ),
        connected: service.connected?,
        connect_path: mastodon_connection_path,
        disconnect_path: mastodon_connection_path
      )
    end

    # @return [ConnectedAppPresenter, nil] Nil without the Meta app credentials, thus the page
    #   hides the card.
    def threads_app
      service = Threads.new
      return unless service.valid_credentials?

      ConnectedAppPresenter.new(
        name: t("admin.networks.threads"),
        description: card_description(
          connected: service.connected?,
          account: ("@#{service.username}" if service.username.present?),
          summary: t("admin.connected_apps.summary.threads")
        ),
        connected: service.connected?,
        connect_path: threads_authorize_path,
        disconnect_path: threads_connection_path,
        error: threads_error_message(service)
      )
    end

    # ⚠️ A Threads token that expires is dead for all time, and only a new authorization corrects
    # that. Thus the card must say two things: that a refresh was refused, while the token is still
    # good, and that the token expired, because `connected?` stays true with the dead token in the
    # store.
    # @param service [Threads]
    # @return [String, nil] A sentence for the card, or nil when the connection works.
    def threads_error_message(service)
      return unless service.connected?

      if service.expired?
        # ⚠️ Two complete keys, and not one sentence with a fragment in the middle of it. The date
        # is optional, thus the code selects a whole sentence.
        date = formatted_date(service.expires_at)
        if date
          t("admin.connected_apps.threads.expired_on", date: date)
        else
          t("admin.connected_apps.threads.expired")
        end
      else
        refresh_error_message(service.refresh_error, name: t("admin.networks.threads"),
                              consequence: t("admin.connected_apps.threads.consequence"))
      end
    end

    # @return [ConnectedAppPresenter, nil] Nil without the Whoop OAuth credentials, thus the page
    #   hides the card.
    def whoop_app
      service = Whoop.new
      return unless service.valid_credentials?

      connected = service.connected?

      ConnectedAppPresenter.new(
        name: t("admin.networks.whoop"),
        description: card_description(
          connected: connected,
          account: service.account_email,
          summary: t("admin.connected_apps.summary.whoop")
        ),
        connected: connected,
        connect_path: "/whoop/auth",
        disconnect_path: whoop_connection_path,
        error: (refresh_error_message(service.refresh_error, name: t("admin.networks.whoop"),
                                      consequence: t("admin.connected_apps.whoop.consequence")) if connected)
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

      if account.present?
        t("admin.connected_apps.account.named", account: account)
      else
        t("admin.connected_apps.account.unnamed")
      end
    end

    # Whoop and Threads both keep their tokens in Redis after the service refuses them, thus
    # `connected?` alone cannot show the difference between an integration that works and one that
    # does not. The scheduled refresh job would continue to fail below a green badge.
    # @param error [Hash, nil] The `{ code:, at: }` of the last refused refresh.
    # @param name [String] The name of the service.
    # @param consequence [String] What stays broken until the owner reconnects.
    # @return [String, nil] A sentence for the card, or nil when the last refresh was successful.
    def refresh_error_message(error, name:, consequence:)
      return if error.blank?

      date = formatted_date(Time.zone.parse(error[:at].to_s))
      key = date ? "on_date" : "plain"
      t("admin.connected_apps.refresh_error.#{key}",
        name: name, code: error[:code], date: date, consequence: consequence)
    end

    # @param time [Time, nil]
    # @return [String, nil] The date to name in a sentence, or nil with no time.
    def formatted_date(time)
      time&.in_time_zone&.strftime("%B %-e, %Y at %-I:%M %p %Z")
    end
  end
end
