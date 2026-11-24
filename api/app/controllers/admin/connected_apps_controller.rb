module Admin
  # Lists the external apps whose credentials this app holds, and lets the owner connect one or
  # disconnect one. The page is a list, thus a new app needs only a new presenter at the end.
  class ConnectedAppsController < BaseController
    # GET /connected-apps
    #
    # ⚠️ A card is on the page only when its integration can operate. Whoop, Threads, and Strava
    # need credentials in the environment, thus without those the page hides the card and offers
    # no action that cannot work. For Bluesky, Mastodon, and TrainerRoad the credentials are the
    # connection, thus those cards are always here and the list is never empty.
    def show
      @apps = [ bluesky_app, mastodon_app, strava_app, threads_app, trainer_road_app, whoop_app ].compact
    end

    private

    def bluesky_app
      service = StandardSite.new

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

    # @return [ConnectedAppPresenter, nil] Nil without the Strava app credentials, thus the page
    #   hides the card.
    def strava_app
      service = Strava.new
      return unless service.valid_credentials?

      ConnectedAppPresenter.new(
        name: t("admin.networks.strava"),
        description: card_description(
          connected: service.connected?,
          account: service.athlete_name,
          summary: t("admin.connected_apps.summary.strava")
        ),
        connected: service.connected?,
        connect_path: strava_authorize_path,
        disconnect_path: strava_connection_path,
        error: (refresh_error_message(service.refresh_error, name: t("admin.networks.strava"),
                                      consequence: t("admin.connected_apps.strava.consequence")) if service.connected?)
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

    # ⚠️ The card must say two things: that a refresh was refused, while the token is still good,
    # and that the token expired. An expired Threads token needs a new authorization, and
    # `connected?` stays true with that token in the store.
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

    # ⚠️ This card names no account: a feed has none, and the rule at #card_description stops a
    # request for the name of the calendar.
    def trainer_road_app
      service = TrainerRoad.new

      ConnectedAppPresenter.new(
        name: t("admin.networks.trainer_road"),
        description: card_description(
          connected: service.connected?,
          account: nil,
          summary: t("admin.connected_apps.summary.trainer_road")
        ),
        connected: service.connected?,
        connect_path: trainer_road_connection_path,
        disconnect_path: trainer_road_connection_path
      )
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
        connect_path: whoop_authorize_path,
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
    # @param account [String, nil] The name of that account, in the form of its own service.
    # @param summary [String] The line to show when nothing is connected: what the integration does.
    def card_description(connected:, account:, summary:)
      return summary unless connected

      if account.present?
        t("admin.connected_apps.account.named", account: account)
      else
        t("admin.connected_apps.account.unnamed")
      end
    end

    # Whoop, Threads, and Strava each keep their tokens in Redis after the service refuses them.
    # Thus `connected?` alone cannot show whether an integration works, and the scheduled refresh
    # job would continue to fail below a green badge.
    # @param error [Hash, nil] The `{ code:, at: }` of the last refused refresh.
    # @param consequence [String] What stays broken until the owner reconnects.
    # @return [String, nil] A sentence for the card, or nil when the last refresh was successful.
    def refresh_error_message(error, name:, consequence:)
      return if error.blank?

      date = formatted_date(Time.zone.parse(error[:at].to_s))
      key = date ? "on_date" : "plain"
      t("admin.connected_apps.refresh_error.#{key}",
        name: name, code: error[:code], date: date, consequence: consequence)
    end

    # @return [String, nil] The date to name in a sentence, or nil with no time.
    def formatted_date(time)
      time&.in_time_zone&.strftime("%B %-e, %Y at %-I:%M %p %Z")
    end
  end
end
