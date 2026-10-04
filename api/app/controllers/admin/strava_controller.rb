module Admin
  # Connects a Strava athlete with the OAuth2 authorization code flow. The app credentials come from
  # the environment, thus there is no form, as for Threads.
  #
  # ⚠️ The callback is an admin page, thus the owner session controls it, and the one-time state
  # value controls it a second time.
  class StravaController < BaseController
    include OauthState

    # GET /connected-apps/strava/authorize
    def authorize
      url = Strava.new.authorization_url(issue_oauth_state(:strava), redirect_uri: strava_callback_url)

      if url.nil?
        redirect_to connected_apps_path, status: :see_other, alert: t("admin.strava.flash.unconfigured")
      else
        redirect_to url, allow_other_host: true
      end
    end

    # GET /connected-apps/strava/callback
    def callback
      return connection_denied(t("admin.strava.flash.unauthorized", error: params[:error])) if params[:error].present?
      return connection_denied(t("admin.oauth.invalid_state")) unless valid_oauth_state?(:strava, params[:state])
      # ⚠️ The athlete can clear a scope on the Strava screen, and the token then cannot edit the
      # activities. A connection that cannot do its one job is not a connection.
      return connection_denied(t("admin.strava.flash.missing_scope")) unless Strava.granted_scopes?(params[:scope])

      if params[:code].present? && Strava.new.connect!(params[:code])
        consume_oauth_state(:strava)
        redirect_to connected_apps_path, notice: t("admin.strava.flash.connected")
      else
        connection_denied(t("admin.strava.flash.no_token"))
      end
    end

    # DELETE /connected-apps/strava
    def destroy
      Strava.new.disconnect!
      redirect_to connected_apps_path, status: :see_other, notice: t("admin.strava.flash.disconnected")
    end

    private

    # Sends the owner back to the Connected apps page with the cause.
    # @param message [String]
    def connection_denied(message)
      redirect_to connected_apps_path, status: :see_other, alert: message
    end
  end
end
