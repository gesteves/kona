module Admin
  # Lists the external apps whose credentials this app holds, and lets the owner connect one or
  # disconnect one. The page is a list, thus a new app needs only a new presenter at the end.
  class ConnectedAppsController < BaseController
    # GET /connected-apps
    #
    # ⚠️ A card is on the page only when its integration can operate. Whoop, Threads, and Strava
    # need credentials in the environment, thus without those their method gives nil, and the page
    # hides the card and offers no action that cannot work. For Bluesky, Mastodon, and TrainerRoad
    # the credentials are the connection, thus those cards are always here and the list is never
    # empty.
    def show
      @apps = [ bluesky_app, mastodon_app, strava_app, threads_app, trainer_road_app, whoop_app ].compact
    end

    private

    def bluesky_app = card(:bluesky, StandardSite.new, connect_path: bluesky_connection_path)

    def mastodon_app = card(:mastodon, Mastodon.new, connect_path: mastodon_connection_path)

    def trainer_road_app = card(:trainer_road, TrainerRoad.new, connect_path: trainer_road_connection_path)

    def strava_app
      service = Strava.new
      return unless service.configured?

      card(:strava, service, connect_path: strava_authorize_path, disconnect_path: strava_connection_path) do
        refresh_error_message(:strava, service.refresh_error)
      end
    end

    def threads_app
      service = Threads.new
      return unless service.configured?

      card(:threads, service, connect_path: threads_authorize_path, disconnect_path: threads_connection_path) do
        threads_error_message(service)
      end
    end

    def whoop_app
      service = Whoop.new
      return unless service.configured?

      card(:whoop, service, connect_path: whoop_authorize_path, disconnect_path: whoop_connection_path) do
        refresh_error_message(:whoop, service.refresh_error)
      end
    end

    # One card of the page. The name and the summary come from the locale file, below the key.
    # @param key [Symbol] The key of the app in `admin.networks` and `admin.connected_apps.summary`.
    # @param service [#connected?, #account_label] The service of the app.
    # @param disconnect_path [String] The same path as `connect_path` for an app with a form.
    # @yieldreturn [String, nil] The error sentence of a connected app. The block runs only for a
    #   connected app.
    # @return [ConnectedAppPresenter]
    def card(key, service, connect_path:, disconnect_path: connect_path)
      connected = service.connected?

      ConnectedAppPresenter.new(
        name: t("admin.networks.#{key}"),
        description: card_description(connected: connected, account: service.account_label,
                                      summary: t("admin.connected_apps.summary.#{key}")),
        connected: connected,
        connect_path: connect_path,
        disconnect_path: disconnect_path,
        error: (yield if connected && block_given?)
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
        refresh_error_message(:threads, service.refresh_error)
      end
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
    # @param key [Symbol] The key of the app.
    # @param error [Hash, nil] The `{ code:, at: }` of the last refused refresh.
    # @return [String, nil] A sentence for the card, or nil when the last refresh was successful.
    def refresh_error_message(key, error)
      return if error.blank?

      date = formatted_date(Time.zone.parse(error[:at].to_s))
      t("admin.connected_apps.refresh_error.#{date ? 'on_date' : 'plain'}",
        name: t("admin.networks.#{key}"), code: error[:code], date: date,
        consequence: t("admin.connected_apps.#{key}.consequence"))
    end

    # @return [String, nil] The date to name in a sentence, or nil with no time.
    def formatted_date(time)
      time&.in_time_zone&.strftime("%B %-e, %Y at %-I:%M %p %Z")
    end
  end
end
